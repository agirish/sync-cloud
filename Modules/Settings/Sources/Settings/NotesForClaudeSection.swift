import AppKit
import Design
import SwiftUI
import Sync

/// Ask Claude ▸ General ▸ Notes for Claude (TE307): what Claude keeps about them, line by line,
/// each with who wrote it and from which of their words, so it reads at a glance. Edit… opens the
/// Markdown itself, saved only on Save. One self-contained section, so it can move with the page.
public struct NotesForClaudeSection: View {
    @AppStorage(AskClaudeNotes.onKey) private var claudeMayWrite = true
    @State private var text = ""
    @State private var origins: [String: AskClaudeNotes.Origin] = [:]
    @State private var hidden: [String] = []
    /// The Markdown being edited, or nil while the notes are shown.
    @State private var draft: String?
    /// The file as it was at Edit…, so Save can tell whether it changed underneath the draft.
    @State private var base = ""
    /// What went wrong with the last Save or Clear, said under the notes; nil when nothing did.
    @State private var problem: String?
    /// An unsaved edit, kept for the session while the page is gone: switching to Privacy, or
    /// closing Settings, would otherwise drop a half-rewritten note without a word.
    @MainActor private static var unsaved: (draft: String, base: String)?
    /// Built here for tests; the app's own.
    var store = AskClaudeNotes()

    static let caption = "What Claude remembers about you across chats; Undo in the chat takes back an addition. Notes never widen what Claude may do."

    public init() {}

    public var body: some View {
        SettingsSection("Notes for Claude", caption: Self.caption) {
            Toggle("Let Claude add to its notes", isOn: $claudeMayWrite.loggingSettingsChange("intelligence.notesOn"))
                .help("Off, Claude still reads your notes but can’t change them.")
            if let draft {
                editor(draft)
            } else {
                shown
            }
        }
        .onAppear {
            reload()
            if draft == nil, let unsaved = Self.unsaved { base = unsaved.base; draft = unsaved.draft }
        }
        .onChange(of: draft) { _, now in Self.unsaved = now.map { ($0, base) } }
        .onReceive(NotificationCenter.default.publisher(for: AskClaudeNotes.didChange)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: AskClaudePrivacy.didChange)) { _ in reload() }
        // Another editor may have changed the file while SyncCloud was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private func reload() {
        text = store.read()
        origins = store.origins()
        hidden = AskClaudePrivacy.hiddenFolders(in: .standard)
    }

    @ViewBuilder private var shown: some View {
        let lines = AskClaudeNotes.lines(of: text)
        if lines.isEmpty {
            Text("Nothing yet. Claude adds what it learns as you chat, or choose Edit… to write your own.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let flagged = Dictionary(AskClaudeNotes.hiddenMentions(in: text, hidden: hidden).map { ($0.line.number, $0.names) },
                                     uniquingKeysWith: { a, _ in a })
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines, id: \.number) { line in
                    row(line, hiddenNames: flagged[line.number])
                }
            }
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.well))
        }
        footer(text)
        HStack(spacing: 8) {
            Button("Edit…") {
                base = store.read()
                draft = base
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
                .disabled(lines.isEmpty)
                .help("Shows Notes for Claude.md in your home folder. Any editor can change it.")
            Button("Clear Notes…", role: .destructive) {
                let count = lines.filter { !$0.isHeading }.count
                _ = RemovalPrompt.actIfConfirmed(confirm: RemovalPrompt.clearNotesForClaude(lines: count).ask) {
                    problem = store.clear() ? nil : "The notes couldn’t be cleared. Try again, or remove the file in Finder."
                }
            }
            .disabled(lines.isEmpty)
        }
        .controlSize(.small)
        problemLine
    }

    @ViewBuilder private var problemLine: some View {
        if let problem {
            Text(problem)
                .scaledFont(.caption)
                .foregroundStyle(SemanticColor.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ line: AskClaudeNotes.Line, hiddenNames: [String]?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if line.isHeading {
                Text(line.text.uppercased())
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                Text(line.text).fixedSize(horizontal: false, vertical: true)
                Text(Self.provenance(origins[AskClaudeNotes.key(line.text)]))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(origins[AskClaudeNotes.key(line.text)]?.quote.map { "From your words: “\($0)”" } ?? "")
                if let hiddenNames {
                    Text(Self.hiddenWarning(hiddenNames))
                        .scaledFont(.caption)
                        .foregroundStyle(SemanticColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func editor(_ draft: String) -> some View {
        let over = draft.count > AskClaudeNotes.limit
        return VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: Binding(get: { self.draft ?? "" }, set: { self.draft = $0 }))
                .scaledFont(.callout.monospaced())
                .frame(minHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.well))
                .accessibilityLabel("Notes for Claude, as Markdown")
            footer(draft)
            if over {
                Text("Over the limit by \((draft.count - AskClaudeNotes.limit).formatted()) characters. Shorten it to save.")
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
            }
            problemLine
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") {
                    self.draft = nil
                    problem = nil
                }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard Self.maySave(draftOver: base, now: store.read(), confirm: RemovalPrompt.saveOverChangedNotes().ask) else { return }
                    if store.save(draft) {
                        self.draft = nil
                        problem = nil
                        SettingsWindowLog.log("intelligence.notes", "edited by hand")
                    } else {
                        problem = "The notes couldn’t be saved. Your edit is still here; try again."
                    }
                }
                .disabled(over)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accentedProminent()
            }
            .controlSize(.small)
        }
    }

    /// Whether Save may write the draft: at once when the file is as it was at Edit…, else only if
    /// they choose to save over what changed.
    nonisolated public static func maySave(draftOver base: String, now: String, confirm: () -> Bool) -> Bool {
        AskClaudeNotes.substance(base) == AskClaudeNotes.substance(now) || confirm()
    }

    private func footer(_ text: String) -> some View {
        Text(Self.footer(text))
            .scaledFont(.caption)
            .foregroundStyle(text.count > AskClaudeNotes.limit ? AnyShapeStyle(.red)
                : text.count >= AskClaudeNotes.nearlyFull ? AnyShapeStyle(SemanticColor.warning) : AnyShapeStyle(.secondary))
            .monospacedDigit()
    }

    /// After hiding `paths`: offers to take out the note lines that name them. Returns how many
    /// went.
    @MainActor @discardableResult
    public static func offerToRemoveLines(naming paths: [String], store: AskClaudeNotes = AskClaudeNotes(),
                                          confirm: (RemovalPrompt) -> Bool = { $0.ask() }) -> Int {
        let mentions = AskClaudeNotes.hiddenMentions(in: store.read(), hidden: paths)
        guard !mentions.isEmpty else { return 0 }
        var names: [String] = []
        for name in mentions.flatMap(\.names) where !names.contains(name) { names.append(name) }
        guard confirm(RemovalPrompt.removeNoteLines(count: mentions.count, naming: names)) else { return 0 }
        return store.removeLines(naming: paths)
    }

    // MARK: Words, apart from the view so a test reads them

    public nonisolated static func footer(_ text: String) -> String {
        "\(text.count.formatted()) of \(AskClaudeNotes.limit.formatted()) · about \(AskClaudeNotes.estimatedTokens(text).formatted()) tokens · sent with each new chat, and when you change them"
    }

    public nonisolated static func provenance(_ origin: AskClaudeNotes.Origin?, now: Date = Date()) -> String {
        guard let origin else { return "Edited outside SyncCloud" }
        let date = origin.date.formatted(.dateTime.month(.abbreviated).day())
        switch origin.by {
        case .claude: return "Claude · \(date)" + (origin.quote.map { " · from “\($0)”" } ?? "")
        case .you: return "You · \(date)"
        }
    }

    public nonisolated static func hiddenWarning(_ names: [String]) -> String {
        let list = names.joined(separator: ", ")
        return "\(list) \(names.count == 1 ? "is" : "are") on Hidden from Claude. Claude reads this name, never the folder."
    }
}
