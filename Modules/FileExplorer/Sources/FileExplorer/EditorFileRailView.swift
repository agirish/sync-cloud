import SwiftUI
import Design
import Sync

/// The editor's file rail: the text-like files in the selected folder, and the way to add one.
///
/// **A rail rather than a tree.** Changing folder is the sidebar's job, and this list exists so
/// that opening a second file in the folder you are already in does not send you to another
/// workspace and back.
struct EditorFileRailView: View {

    let folderName: String
    let entries: [EditorRailEntry]
    let selectedPath: String?
    let accent: Color
    /// Whether the inline naming row is showing. A binding, because ⌘N opens it from outside this
    /// view — from another workspace, even.
    @Binding var isNaming: Bool
    /// **Held by the host, beside `isNaming`, and this pairing is the point.** `isNaming` was
    /// hoisted because the editor's view does not exist while another workspace is on screen; this
    /// is the one of the two that holds something the USER TYPED, and it was left behind as
    /// `@State`. Typing a name, switching to Browse and switching back left the row open with the
    /// field silently reset — and `onChange(initial: true)` then saw it empty and overwrote it with
    /// `Untitled.md`. The comment on ``cancelNaming()`` promises a row keeps its text; that promise
    /// held for a click elsewhere and not for a tab switch.
    @Binding var typedName: String
    /// Where the OPEN document stands, so its row in the list can say so too. `nil` when nothing
    /// is open. Only the open document can be unsaved, so this needs no path of its own — the row
    /// it belongs to is the selected one.
    var documentStatus: EditorSaveStatus?
    /// A counter the host bumps on every ⌘N.
    ///
    /// **A signal, not a value.** Pressing ⌘N while the row is already open writes `true` over
    /// `true`, which is not a change, so the `onChange` below never fires and focus stays wherever
    /// it was — the second press looked like it did nothing at all.
    var namingFocus: Int = 0
    /// The name the row is prefilled with when it opens. A closure, not a value: resolving it
    /// walks the folder looking for the first free `Untitled`, and as a plain argument that walk
    /// ran on every body pass — which is every keystroke in the editor — whether or not the row
    /// was open.
    let prefilledName: () -> String
    /// Why the typed name cannot be used, asked as the user types.
    let refusal: (String) -> String?
    let onOpen: (EditorRailEntry) -> Void
    /// Commits a name. Returns `false` when the file was not created after all — the caller can
    /// refuse (an unsaved document the user declined to settle), and the row reopens with the typed
    /// name still in it rather than vanishing with the work.
    let onCreate: (String) -> Bool

    /// The rail row's one outline, stated once and used by both the hit shape and the hover wash.
    /// `roundedRect(7)` is what the `.row` variant defaults to; naming it here is what lets the
    /// `.filled` arm — which would otherwise default to a capsule — wear the same shape.
    static let rowShape = HoverAffordanceShape.roundedRect(7)
    static var rowOutline: HoverAffordanceOutline { HoverAffordanceOutline(kind: rowShape) }

    /// The rail's width. See ``EditorLayoutMetrics/railWidth``.
    static var width: CGFloat { EditorLayoutMetrics.railWidth }

    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isNaming { namingRow }
            if entries.isEmpty && !isNaming {
                emptyCaption
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(entries) { entry in row(entry) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width)
        // **`initial: true`, and that is the whole ⌘N-from-another-workspace path.** The editor's
        // view does not exist while another workspace is on screen, so ⌘N sets `isNaming` and
        // *then* this view is constructed — already open. Without `initial:` the change never
        // happened as far as this modifier is concerned, and the row appeared with an empty field,
        // no focus, and a "Type a name for the file." hint under it.
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

    private var header: some View {
        HStack(spacing: 6) {
            Text(folderName.isEmpty ? "Text files" : "Text files in \(folderName)")
                .scaledFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                isNaming = true
            } label: {
                Image(systemName: "plus")
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.hoverAffordance(.glyph, tint: accent))
            .accessibilityLabel("New text file")
            .shortcutKeycap(AppChord.newTextFile.display)
            .help(ShortcutHint.tooltip("New text file", AppChord.newTextFile.display))
            .disabled(folderName.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// The inline naming row — the same bargain New Folder strikes: the field opens, and nothing
    /// exists on disk until Return.
    private var namingRow: some View {
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
    }

    /// Shuts the naming row and forgets what was typed. Esc, and nothing else — a row abandoned by
    /// clicking elsewhere keeps its text, because the next ⌘N is more likely to be a return to it
    /// than a fresh start.
    private func cancelNaming() {
        typedName = ""
        isNaming = false
    }

    private var emptyCaption: some View {
        Text(folderName.isEmpty
             ? "Pick a folder in the sidebar to see the text files in it."
             : "No text files in this folder. The + button makes one.")
            .scaledFont(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.top, 4)
    }

    /// The colour of a row's leading dot, or `nil` for no dot.
    ///
    /// **Only the open row can have one**, which is the whole rule: a rail lists many files and
    /// exactly one of them is the document, so a dot resolved per row from a document-wide status
    /// would mark every file in the folder as unsaved. Asked as a function rather than inline so
    /// that claim is testable — the mistake it guards is invisible in a screenshot of a
    /// one-file folder.
    static func dotColour(rowPath: String, selectedPath: String?,
                          status: EditorSaveStatus?, accent: Color) -> Color? {
        guard rowPath == selectedPath, let status, status.showsDot else { return nil }
        return status.isWarning ? .orange : accent
    }

    /// The width the dot's column always occupies, dot or no dot.
    ///
    /// **Reserved rather than inserted**, because this appears and disappears as you type: a dot
    /// that took its own space would shove every file name in the list sideways on the first
    /// keystroke and back again two seconds later. BBEdit reserves the same column, which is why
    /// its list is still while you type into a document.
    ///
    /// **The reservation is the UNCONDITIONAL `Circle` below, not this number** — a clear fill
    /// still takes part in layout, where an `if let` around the whole shape would not. Worth
    /// stating because the tempting tidy-up is exactly the one that breaks it, and no test here
    /// can catch it: the rail is hard-framed so its width cannot move, and a 5pt dot is shorter
    /// than the 12pt name beside it so the row's height does not move either. Measured — both
    /// mutations were run against a rendered test and neither changed a pixel of the rail's size,
    /// which is why that test was deleted rather than kept as reassurance.
    static let dotColumnWidth: CGFloat = 9

    private func row(_ entry: EditorRailEntry) -> some View {
        let isSelected = entry.path == selectedPath
        let dot = Self.dotColour(rowPath: entry.path, selectedPath: selectedPath,
                                 status: documentStatus, accent: accent)
        return Button {
            onOpen(entry)
        } label: {
            HStack(spacing: 6) {
                // The unsaved marker, before the icon — where BBEdit puts it, and where a column of
                // them reads as a column rather than as punctuation inside the names.
                Circle()
                    .fill(dot ?? .clear)
                    .frame(width: 5, height: 5)
                    .frame(width: Self.dotColumnWidth, alignment: .leading)
                    .accessibilityHidden(dot == nil)
                    .accessibilityLabel("Unsaved")
                Image(systemName: "doc.text")
                    .scaledFont(.system(size: 11))
                Text(entry.name)
                    .scaledFont(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(FileSyncManager.formatBytes(entry.size))
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            // Dim rows keep their full opacity on the SELECTED row: a row you have clicked and
            // that has answered with a caption should not also be hard to read.
            .opacity(entry.isDimmed && !isSelected ? 0.5 : 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Self.rowOutline)
        }
        // **`.row`, and the shape passed explicitly to BOTH arms.**
        //
        // This shipped as `isSelected ? .filled : .inline`, and `.inline` is the wrong variant
        // twice over. It is documented for "a small dismiss glyph riding inside a field or chip",
        // so it washes in ink rather than the accent — and its default shape is a CIRCLE. A circle
        // in a full-width row collapses to the row's height and centres itself, which is what put a
        // grey disc in the middle of the row under the pointer instead of a wash across it. `.row`
        // is the variant written for this exact control: a full-width list row whose whole area is
        // the target, with a quieter wash because it covers so many more pixels than a glyph.
        //
        // The shape is passed rather than left to default because BOTH arms need it: `.filled`
        // defaults to a capsule, so the selected row's hairline ring traced a pill around a rounded
        // rectangle — the mis-shaped-when-selected half of the same defect, which `HoverAffordanceShape`
        // warns about in so many words. One value, used by the style and by `contentShape` above,
        // which is what `HoverAffordanceOutline` exists for.
        .buttonStyle(.hoverAffordance(isSelected ? .filled : .row,
                                      tint: accent, shape: Self.rowShape))
        .help(entry.dimmedReason ?? entry.name)
    }
}
