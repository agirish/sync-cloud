import AppKit
import SwiftUI
import Design
import Sync

/// Past Chats in the Ask Claude column (TE306): the list by day with search, and a past chat opened
/// read-only with Continue. Its own view behind the header's clock button, so the column it sits in
/// can change without it.
struct AskClaudePastChatsView: View {
    @ObservedObject var past: AskClaudePastChats
    /// The chat opened from the list, nil for the list.
    @Binding var opened: UUID?
    let accentFill: Color
    let onAccent: Color
    /// A question is running: Continue waits for it.
    let isRunning: Bool
    let onContinue: (UUID) -> Void
    let onNewChat: () -> Void
    let onOpenSettings: () -> Void

    @State private var query = ""
    @State private var hovered: UUID?
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let id = opened, let entry = past.entries.first(where: { $0.id == id }) {
                detail(entry)
            } else {
                list
            }
        }
        .onAppear { past.refresh() }
        .onDisappear { past.forgetDeleted() }
    }

    // MARK: The list

    private var list: some View {
        let shown = past.search(query)
        return VStack(spacing: 0) {
            if !past.entries.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search chats", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { if let first = shown.first { opened = first.id } }
                        .accessibilityLabel("Search past chats")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Clear search")
                            .accessibilityLabel("Clear search")
                    }
                }
                .scaledFont(.callout)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.chip))
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                // The list was opened to find a chat: the field takes the keyboard. No ⌘F of its
                // own, which would take Find in Pane from the whole window.
                .onAppear { searchFocused = true }
            }
            if past.entries.isEmpty {
                empty(title: "No past chats yet",
                      text: "When you start a new chat, or come back after an hour away, the last one is kept here \(keptFor).")
            } else if shown.isEmpty {
                empty(title: "No chats mention “\(query)”", text: "Search covers your questions and Claude’s answers, not what’s inside files.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Self.days(shown)) { day in
                            Text(day.title)
                                .scaledFont(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 3)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(day.entries) { entry in row(entry) }
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 8)
                }
            }
            if let deleted = past.lastDeleted {
                HStack(spacing: 8) {
                    Text("Deleted “\(deleted.title)”").lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Button("Undo") { past.undoDelete() }.buttonStyle(.link)
                }
                .scaledFont(.caption)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.chip))
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
            Divider()
            HStack {
                Text(footer).foregroundStyle(.secondary)
                Spacer()
                Button("Settings…", action: onOpenSettings).buttonStyle(.link)
                    .help("How long chats are kept, and Clear All")
            }
            .scaledFont(.caption)
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    private var keptFor: String {
        switch past.keep {
        case .week: "for 7 days"
        case .month: "for 30 days"
        case .forever: "until you delete it"
        }
    }

    private var footer: String {
        guard !query.isEmpty else { return past.described ?? "No chats" }
        return "\(past.search(query).count) of \(past.entries.count) · searched on this Mac"
    }

    private func empty(title: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "clock").scaledFont(.title).foregroundStyle(.tertiary)
            Text(title).scaledFont(.callout.weight(.semibold))
            Text(text).scaledFont(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func row(_ entry: AskClaudePastChats.Entry) -> some View {
        let match = query.isEmpty ? nil : entry.match(query)
        // The bin sits beside the row's button, not in it: a button inside another's label loses
        // its click to the outer one.
        return ZStack(alignment: .bottomTrailing) {
            Button { opened = entry.id } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.firstQuestion).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 6)
                        Text(entry.lastAsked, format: .dateTime.hour().minute())
                            .scaledFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let match {
                        Text(match).scaledFont(.caption).lineLimit(1).truncationMode(.tail)
                    }
                    Text(entry.detail).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.trailing, 24)
                }
                .scaledFont(.callout)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered == entry.id ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: Radius.chip))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "Delete") { past.delete(entry.id) }
            .accessibilityAction(named: "Continue") { onContinue(entry.id) }
            if hovered == entry.id {
                Button { past.delete(entry.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).controlSize(.small)
                    .padding(.trailing, 8).padding(.bottom, 5)
                    .help("Delete this chat")
                    .accessibilityLabel("Delete")
            }
        }
        .onHover { inside in hovered = inside ? entry.id : (hovered == entry.id ? nil : hovered) }
        // Built once at its first opening on macOS 27, so nothing in it may change with state:
        // Continue says no price here, and does nothing while a question runs.
        .contextMenu {
            Button("Open") { opened = entry.id }
            Button("Continue") { onContinue(entry.id) }
            Button("Copy as Text") { Self.copy(entry) }
            Divider()
            Button("Delete Chat") { past.delete(entry.id) }
        }
    }

    // MARK: A past chat

    private func detail(_ entry: AskClaudePastChats.Entry) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // Esc goes back too, through the column's own Esc, not a window-wide shortcut.
                Button { opened = nil } label: { Label("Past Chats", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text(Self.dayTitle(entry.lastAsked) + ", " + entry.lastAsked.formatted(.dateTime.hour().minute())
                     + (entry.folder.map { " · " + $0 } ?? ""))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .scaledFont(.caption)
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            ScrollView {
                AskClaudePastLinesView(lines: entry.lines, accentFill: accentFill, onAccent: onAccent)
                    .padding(12)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text(Self.continueWhy(entry.resume)).scaledFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("New Chat", action: onNewChat).frame(maxWidth: .infinity)
                    Button(continueTitle(entry.resume)) { onContinue(entry.id) }
                        .buttonStyle(.borderedProminent).accentedProminent()
                        .disabled(isRunning)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(12)
        }
    }

    private func continueTitle(_ resume: AskClaudePastChats.Resume) -> String {
        Self.continueTitle(resume)
    }

    static func continueTitle(_ resume: AskClaudePastChats.Resume) -> String {
        switch resume {
        case .readBack(let cost, _): cost > 0 ? "Continue · \(AskClaudeSpend.format(cost))" : "Continue"
        case .asText(_, let cost): cost > 0 ? "Continue in a New Chat · \(AskClaudeSpend.format(cost))" : "Continue in a New Chat"
        }
    }

    static func continueWhy(_ resume: AskClaudePastChats.Resume) -> String {
        switch resume {
        case .readBack(let cost, let tokens):
            tokens > 0
                ? "Continue reads this chat back in to Claude once: \(tokens.formatted()) tokens, about \(AskClaudeSpend.format(cost)). Cards here are a record; their Undo ended with the chat."
                : "Continue picks this chat up where it was. Cards here are a record; their Undo ended with the chat."
        case .asText(let reason, let cost):
            reason + " Continue starts a new chat that carries it as text, about \(AskClaudeSpend.format(cost)). What Claude read from files isn’t carried."
        }
    }

    private static func copy(_ entry: AskClaudePastChats.Entry) {
        let text = entry.lines.compactMap { line -> String? in
            switch line {
            case .question(let q, _): "You: " + q
            case .answer(let a): "Claude: " + a
            case .card(_, let c): "[" + c + "]"
            case .meta: nil
            }
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Days

    struct Day: Identifiable {
        let title: String
        let entries: [AskClaudePastChats.Entry]
        /// Its first chat's: a title can come twice ("9 November" of two years kept apart).
        var id: UUID { entries[0].id }
    }

    /// The entries in runs by day, newest first, under "Today", "Yesterday", a weekday this week, or
    /// a date.
    static func days(_ entries: [AskClaudePastChats.Entry], now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        var days: [Day] = []
        for entry in entries {
            let title = dayTitle(entry.lastAsked, now: now, calendar: calendar)
            if days.last?.title == title {
                days[days.count - 1] = Day(title: title, entries: days[days.count - 1].entries + [entry])
            } else {
                days.append(Day(title: title, entries: [entry]))
            }
        }
        return days
    }

    static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        var style = Date.FormatStyle.dateTime
        style.timeZone = calendar.timeZone
        if days < 7 { return date.formatted(style.weekday(.wide)) }
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            return date.formatted(style.day().month(.wide).year())
        }
        return date.formatted(style.day().month(.wide))
    }
}

/// A past chat's lines, read-only: questions, answers, what happened, and each card as one line.
struct AskClaudePastLinesView: View, Equatable {
    let lines: [AskClaudePastChats.Line]
    let accentFill: Color
    let onAccent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .question(let text, let spoken):
                    (spoken ? Text("\(Image(systemName: "mic")) \(text)") : Text(text))
                        .textSelection(.enabled)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .foregroundStyle(onAccent)
                        .background(accentFill, in: RoundedRectangle(cornerRadius: Radius.card))
                        // Its own element over the selectable text, as the live thread's bubble is:
                        // a label on the text itself loops in AppKit and crashes the app.
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel("You: \(text)")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                case .answer(let text):
                    AskClaudeAnswerView(blocks: AskClaudeMarkdown.blocks(text))
                        .tint(accentFill)
                case .meta(let text):
                    Text(text).scaledFont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .card(let symbol, let text):
                    Label(text, systemImage: symbol)
                        .scaledFont(.caption)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.chip))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The line between a chat Claude no longer has and what follows (decision JK), with Continue on it
/// while nothing has been asked since.
struct AskClaudeEarlierLine: View {
    let title: String
    let resume: AskClaudePastChats.Resume?
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                line
                Text(title).scaledFont(.caption).foregroundStyle(.secondary).layoutPriority(1)
                    .multilineTextAlignment(.center)
                line
            }
            if let resume {
                HStack {
                    Spacer()
                    Button(AskClaudePastChatsView.continueTitle(resume), action: onContinue)
                        .controlSize(.small)
                        .help(AskClaudePastChatsView.continueWhy(resume))
                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var line: some View {
        Rectangle().fill(.separator).frame(height: 1)
    }
}
