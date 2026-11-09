import Design
import SwiftUI
import Sync

/// What a Refine card needs from the app: the click, and the folder list Customize… edits.
struct AskClaudeRefineBridge {
    /// Send, on the person's click. Never from anything typed or spoken (TE335, KE).
    var send: @MainActor (_ item: UUID) -> Void = { _ in }
    /// Send only the part that fits under the monthly limit.
    var sendFit: @MainActor (_ item: UUID) -> Void = { _ in }
    var cancel: @MainActor (_ item: UUID) -> Void = { _ in }
    var stop: @MainActor (_ item: UUID) -> Void = { _ in }
    /// The tick: page 1 from folders that ask each time. Re-quotes the plan.
    var setTick: @MainActor (_ item: UUID, _ on: Bool) -> Void = { _, _ in }
    /// Ask again about the files answered before. Re-quotes the plan.
    var askAgain: @MainActor (_ item: UUID) -> Void = { _ in }
    /// The folders Customize… can leave out, and the ones left out now.
    var folders: @MainActor () -> [String] = { [] }
    var leftOut: @MainActor () -> Set<String> = { [] }
    /// Leaves folders out of the list for the session; re-quotes the plan.
    var setLeftOut: @MainActor (_ item: UUID, _ folders: Set<String>) -> Void = { _, _ in }
    /// Opens Settings ▸ Ask Claude ▸ Key & Spending.
    var changeLimit: @MainActor () -> Void = {}
    var undo: @MainActor (_ item: UUID) -> Void = { _ in }
    var canUndo: @MainActor (_ item: UUID) -> Bool = { _ in false }
    /// Opens a card's file in its folder.
    var reveal: @MainActor (_ path: String) -> Void = { _ in }
}

/// The Refine plan, its request and its answers, as one card in the thread. Designed for 240 pt:
/// lines wrap, buttons sit under the words, Send is last.
struct AskClaudeRefineCardView: View {
    let itemID: UUID
    let card: AskClaudeRefineCard
    let bridge: AskClaudeRefineBridge
    let accent: Color
    let hue: LiquidGlassHue
    /// The chat is answering a question. It does not stop a pass, so it only informs.
    var isRunning = false

    @State private var showsAll = false
    @State private var customizing = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch card.phase {
            case .planned: planned
            case .sending(let answered): sending(answered)
            case .done: done
            case .closed, .replaced, .expired: closed
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .contain)
    }

    // MARK: The plan

    @ViewBuilder private var planned: some View {
        if card.plan.nothingNew {
            Label(card.nothingNewTitle, systemImage: "checkmark.circle").scaledFont(.headline)
            Text(card.nothingNewMessage).scaledFont(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("Asking again would send \(card.plan.reused == 1 ? "it" : "all \(card.plan.reused)") to Claude" + (card.plan.costUSD.map { " and cost about \(AskClaudeSpend.format($0))" } ?? "") + ".")
                .scaledFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("Close") { bridge.cancel(itemID) }
                Button("Ask Again About the \(card.plan.reused)") { bridge.askAgain(itemID) }
                    .buttonStyle(.borderedProminent).accentedProminent()
            }
            .controlSize(.small)
        } else if let blocked = card.blockedMessage {
            Label(card.title, systemImage: "sparkles").scaledFont(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(blocked).scaledFont(.callout).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(minLength: 0); Button("OK") { bridge.cancel(itemID) }.controlSize(.small) }
        } else {
            Label(card.title, systemImage: "sparkles").scaledFont(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(AskClaudeRefineCard.promise).scaledFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = card.cutNote {
                Text(note).scaledFont(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = card.notice {
                Label(notice, systemImage: "info.circle").scaledFont(.callout)
                    .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in lineView(line) }
            Divider()
            Text(card.quoteLine).scaledFont(.callout).fixedSize(horizontal: false, vertical: true)
            if let month = card.monthLine {
                Text(month).scaledFont(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            if let limit = card.limitMessage {
                Label(limit, systemImage: "exclamationmark.triangle").scaledFont(.callout)
                    .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }
            planButtons
        }
    }

    @ViewBuilder private func lineView(_ line: AskClaudeRefineCard.Line) -> some View {
        switch line.kind {
        case .tick:
            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: Binding(get: { card.plan.ticked }, set: { bridge.setTick(itemID, $0) })) {
                    Text(line.text).scaledFont(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .disabled(!card.canTick)
                if let detail = line.detail {
                    Text(detail).scaledFont(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
            }
        case .goes:
            VStack(alignment: .leading, spacing: 2) {
                Label { Text(line.text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "arrow.up") }
                    .scaledFont(.callout)
                if let detail = line.detail {
                    HStack(spacing: 6) {
                        Text(detail).scaledFont(.footnote).foregroundStyle(.secondary)
                        if line.text.hasPrefix("Your folder names") { customizeButton }
                    }
                    .padding(.leading, 20)
                } else if line.text.hasPrefix("Your folder names") {
                    customizeButton.padding(.leading, 20)
                }
            }
        case .notSent:
            VStack(alignment: .leading, spacing: 2) {
                Label { Text(line.text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "xmark") }
                    .scaledFont(.callout).foregroundStyle(.secondary)
                if let detail = line.detail {
                    Text(detail).scaledFont(.footnote).foregroundStyle(.secondary).padding(.leading, 20)
                }
            }
        case .reused:
            VStack(alignment: .leading, spacing: 2) {
                Label { Text(line.text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "arrow.uturn.backward") }
                    .scaledFont(.callout).foregroundStyle(.secondary)
                Button(line.detail ?? "Ask Again") { bridge.askAgain(itemID) }
                    .buttonStyle(.link).controlSize(.small).padding(.leading, 20)
            }
        }
    }

    private var customizeButton: some View {
        Button("Customize…") { customizing = true }
            .buttonStyle(.link).controlSize(.small)
            .popover(isPresented: $customizing, arrowEdge: .bottom) {
                AskClaudeRefineFoldersPopover(itemID: itemID, bridge: bridge)
                    .presentedNativeControlAccent()
            }
            .help("Leave folder names out of what Claude sees, for Refine, Try Another and Refine Names until you quit.")
    }

    private var planButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isRunning ? "Claude is answering a question. This waits for nothing: Send when you like."
                           : "Send is the only way to start it")
                .scaledFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Side by side when they fit; stacked, right-aligned, when the panel is at its narrowest.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { Spacer(minLength: 0); planActions }
                VStack(alignment: .trailing, spacing: 6) { planActions }
            }
        }
        .controlSize(.small)
        .padding(.top, 2)
    }

    @ViewBuilder private var planActions: some View {
        Button("Cancel") { bridge.cancel(itemID) }
        if card.plan.exceedsLimit {
            Button("Change Limit…") { bridge.changeLimit() }
            if let fit = card.sendFitTitle {
                Button(fit) { bridge.sendFit(itemID) }
                    .buttonStyle(.borderedProminent).accentedProminent()
            }
        } else {
            Button(card.sendTitle) { bridge.send(itemID) }
                .buttonStyle(.borderedProminent).accentedProminent()
                .disabled(!card.canSend)
                .help("Sends this one request to Claude. Nothing moves until you File it in Organize.")
        }
    }

    // MARK: Sending

    @ViewBuilder private func sending(_ answered: Int?) -> some View {
        Label(card.sendingTitle, systemImage: "sparkles").scaledFont(.headline)
            .fixedSize(horizontal: false, vertical: true)
        if card.plan.downloads > 0 {
            Text("\(card.plan.downloads) cloud-only \(card.plan.downloads == 1 ? "file" : "files") downloaded to read page 1")
                .scaledFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(card.progressLine(answered: answered)).scaledFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Stop") { bridge.stop(itemID) }.controlSize(.small)
        }
    }

    // MARK: After

    @ViewBuilder private var done: some View {
        if let answers = card.answers {
            if let title = card.endingTitle {
                Label(title, systemImage: "exclamationmark.triangle").scaledFont(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = card.endingMessage {
                    Text(message).scaledFont(.callout).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label(card.answersTitle, systemImage: "checkmark.circle").scaledFont(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !answers.rows.isEmpty { rows(answers) }
            if let note = card.answersFootnote {
                Text(note).scaledFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if answers.undone {
                Label("Undone. The on-device suggestions are back.", systemImage: "arrow.uturn.backward")
                    .scaledFont(.callout).foregroundStyle(.secondary)
            } else if !answers.rows.isEmpty {
                Text("Nothing moves until you File it in Organize.").scaledFont(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if bridge.canUndo(itemID) { Button("Undo Refine") { bridge.undo(itemID) } }
                }
                .controlSize(.small)
            }
            if let receipt = card.receiptLine {
                Label(receipt, systemImage: "info.circle").labelStyle(.titleOnly)
                    .scaledFont(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func rows(_ answers: AskClaudeRefineCard.Answers) -> some View {
        let shown = showsAll ? answers.rows : Array(answers.rows.prefix(AskClaudeRefineCard.rowsShown))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Button(row.name) { bridge.reveal(row.path) }
                        .buttonStyle(.link).scaledFont(.callout)
                    Text((row.before.map { "\($0) → " } ?? "No folder → ") + row.after)
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = row.reason, !reason.isEmpty {
                        Text(reason).scaledFont(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if answers.rows.count > AskClaudeRefineCard.rowsShown {
                Button(showsAll ? "Show Fewer" : "Show All \(answers.rows.count)") { showsAll.toggle() }
                    .buttonStyle(.link).controlSize(.small)
            }
        }
    }

    // MARK: Closed

    @ViewBuilder private var closed: some View {
        Label(card.title, systemImage: "sparkles").scaledFont(.headline)
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let line = card.closedLine {
            Text(line).scaledFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Customize…: the folder names Claude is shown, with the ones to leave out ticked off. Held for the
/// session by the manager, so Refine, Try Another and Refine Names follow one rule.
private struct AskClaudeRefineFoldersPopover: View {
    let itemID: UUID
    let bridge: AskClaudeRefineBridge
    @State private var left: Set<String> = []
    @State private var query = ""

    var body: some View {
        let folders = bridge.folders().filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 8) {
            Text("Folder names Claude is shown").scaledFont(.headline)
            Text("Untick a folder to leave its name, and the names under it, out. This lasts until you quit, for Refine, Try Another and Refine Names.")
                .scaledFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Filter", text: $query).textFieldStyle(.roundedBorder).controlSize(.small)
            List(folders, id: \.self) { folder in
                Toggle(isOn: Binding(get: { !left.contains(folder) }, set: { shown in
                    if shown { left.remove(folder) } else { left.insert(folder) }
                })) { Text(folder).scaledFont(.callout).lineLimit(1).truncationMode(.middle) }
                    .toggleStyle(.checkbox)
            }
            .frame(minHeight: 160, maxHeight: 280)
            HStack {
                Button("Reset") { left = [] }.disabled(left.isEmpty)
                Spacer()
                Button("Done") { bridge.setLeftOut(itemID, left) }
                    .buttonStyle(.borderedProminent).accentedProminent()
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { left = bridge.leftOut() }
    }
}
