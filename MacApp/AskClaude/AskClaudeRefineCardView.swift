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
    /// The tick: page 1 from folders that aren't shared with Claude. Re-quotes the plan.
    var setTick: @MainActor (_ item: UUID, _ on: Bool) -> Void = { _, _ in }
    /// Ask again about the files answered before. Re-quotes the plan.
    var askAgain: @MainActor (_ item: UUID) -> Void = { _ in }
    /// Makes a new plan for the files a stopped or failed pass left unanswered.
    var retry: @MainActor (_ item: UUID) -> Void = { _ in }
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

/// The small circled i beside a line: the reason behind it, as a tooltip and as VoiceOver's help.
/// The card states each fact in a few words; whatever explains it lives here.
struct AskClaudeInfoMark: View {
    let text: String

    var body: some View {
        Image(systemName: "info.circle")
            .scaledFont(.system(size: 11))
            .foregroundStyle(.secondary)
            .help(text)
            .accessibilityLabel("More information")
            .accessibilityHint(text)
    }
}

/// The Refine plan, its request and its answers, as one card in the thread. Designed for 240 pt:
/// lines wrap, buttons sit under the words, Send is last. A plan that has closed shrinks to one
/// muted line.
struct AskClaudeRefineCardView: View {
    let itemID: UUID
    let card: AskClaudeRefineCard
    let bridge: AskClaudeRefineBridge
    let accent: Color
    let hue: LiquidGlassHue
    /// The chat is answering a question. It does not stop a pass, so it only informs.
    var isRunning = false

    @State private var showsAll = false
    @State private var showsFiles = false
    @State private var customizing = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let line = card.closedLine {
            // A closed plan is a line, not a card: nothing here needs reading past.
            Text(line)
                .scaledFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                switch card.phase {
                case .planned: planned
                case .sending: sending
                case .done: done
                case .closed, .replaced, .expired: EmptyView()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Pieces

    private func heading(_ text: String, symbol: String = "sparkles", tint: Color? = nil) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol).foregroundStyle(tint ?? accent) }
            .scaledFont(.headline)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).scaledFont(.system(size: 10, weight: .semibold)).tracking(0.6)
            .foregroundStyle(.secondary).padding(.top, 3)
    }

    private func note(_ text: String, info: String? = nil, warning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(text).fixedSize(horizontal: false, vertical: true)
            if let info { AskClaudeInfoMark(text: info) }
            Spacer(minLength: 0)
        }
        .scaledFont(.callout)
        .foregroundStyle(warning ? ChromeInk.bodyText(colorScheme, SemanticColor.warning) : Color.primary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(warning ? SemanticColor.warning.opacity(0.14) : Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.chip))
    }

    private func countLine(_ line: AskClaudeRefineCard.CountLine, muted: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.count).scaledFont(.callout).fontWeight(.semibold).monospacedDigit()
                .frame(minWidth: 26, alignment: .trailing)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(line.text).fixedSize(horizontal: false, vertical: true)
                if let info = line.info { AskClaudeInfoMark(text: info) }
            }
            .scaledFont(.callout)
            Spacer(minLength: 4)
            if let action = line.action { actionLink(action) }
        }
        .foregroundStyle(muted ? Color.secondary : Color.primary)
    }

    @ViewBuilder private func actionLink(_ action: AskClaudeRefineCard.CountLine.Action) -> some View {
        switch action {
        case .whichFiles:
            Button { showsFiles.toggle() } label: {
                HStack(spacing: 2) { Text("Which Files"); Image(systemName: showsFiles ? "chevron.up" : "chevron.down").imageScale(.small) }
            }
            .buttonStyle(.link).controlSize(.small)
        case .customize:
            Button("Customize…") { customizing = true }
                .buttonStyle(.link).controlSize(.small)
                .popover(isPresented: $customizing, arrowEdge: .bottom) {
                    AskClaudeRefineFoldersPopover(itemID: itemID, bridge: bridge)
                        .presentedNativeControlAccent()
                }
        case .askAgain:
            Button("Ask Again") { bridge.askAgain(itemID) }
                .buttonStyle(.link).controlSize(.small)
        }
    }

    // MARK: The plan

    @ViewBuilder private var planned: some View {
        switch card.layout {
        case .nothingNew: nothingNew
        case .blocked: blocked
        case .needsFirstPages: needsFirstPages
        case .overLimit: overLimit
        case .normal: normal
        }
    }

    @ViewBuilder private var noticeRow: some View {
        if let notice = card.notice { note(notice, warning: true) }
    }

    private var normal: some View {
        VStack(alignment: .leading, spacing: 9) {
            heading(card.title)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(AskClaudeRefineCard.promise).fixedSize(horizontal: false, vertical: true)
                AskClaudeInfoMark(text: AskClaudeRefineCard.promiseInfo)
            }
            .scaledFont(.footnote).foregroundStyle(.secondary)
            noticeRow
            if let cut = card.cutNote { Text(cut).scaledFont(.callout).fixedSize(horizontal: false, vertical: true) }
            label("Goes to Claude")
            ForEach(card.goesLines, id: \.text) { countLine($0) }
            if showsFiles { filesList }
            okBlock
            let notSent = card.notSentLines
            if !notSent.isEmpty {
                label("Not sent")
                ForEach(notSent, id: \.text) { countLine($0, muted: true) }
            }
            Divider()
            monthRow
            planButtons
        }
    }

    private var needsFirstPages: some View {
        VStack(alignment: .leading, spacing: 9) {
            heading(card.title)
            noticeRow
            if let n = card.needsFirstPagesNote { note(n.text, info: n.info) }
            ForEach(card.waitingNames, id: \.self) { name in
                Text(name).scaledFont(.callout).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
            }
            if card.plan.waitingForPage > card.waitingNames.count {
                Text("and \(card.plan.waitingForPage - card.waitingNames.count) more").scaledFont(.footnote).foregroundStyle(.secondary)
            }
            okBlock
            if let hint = card.tickHint { Text(hint).scaledFont(.footnote).foregroundStyle(.secondary) }
            monthRow
            planButtons
        }
    }

    private var overLimit: some View {
        VStack(alignment: .leading, spacing: 9) {
            heading(card.title)
            noticeRow
            if let message = card.limitMessage { note(message, info: AskClaudeRefineCard.limitInfo, warning: true) }
            countLine(card.wholePlanLine)
            if showsFiles { filesList }
            if let fit = card.fitLine { countLine(fit) }
            if let fraction = card.monthFraction { ProgressView(value: fraction).progressViewStyle(.linear) }
            planButtons
        }
    }

    private var nothingNew: some View {
        VStack(alignment: .leading, spacing: 9) {
            heading(card.nothingNewTitle, symbol: "checkmark.circle")
            note(card.nothingNewMessage, info: card.nothingNewInfo)
            if card.plan.hidden > 0 {
                countLine(.init(count: "\(card.plan.hidden)", text: "hidden from Claude", info: nil, action: nil), muted: true)
            }
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                Button("Close") { bridge.cancel(itemID) }
                Button("Ask Again") { bridge.askAgain(itemID) }
                    .buttonStyle(.borderedProminent).accentedProminent()
            }
            .controlSize(.small)
        }
    }

    private var blocked: some View {
        VStack(alignment: .leading, spacing: 9) {
            heading(card.title)
            if let message = card.blockedMessage { Text(message).scaledFont(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(minLength: 0); Button("OK") { bridge.cancel(itemID) }.controlSize(.small) }
        }
    }

    /// The one decision: a tick, worded as what leaves the Mac, with what it buys beneath.
    @ViewBuilder private var okBlock: some View {
        if let ok = card.ok {
            label("Needs your OK")
            VStack(alignment: .leading, spacing: 3) {
                Toggle(isOn: Binding(get: { card.plan.ticked }, set: { bridge.setTick(itemID, $0) })) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(ok.title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                        AskClaudeInfoMark(text: ok.info)
                    }
                    .scaledFont(.callout)
                }
                .toggleStyle(.checkbox)
                .disabled(!card.canTick)
                if let detail = ok.detail {
                    Text(detail).scaledFont(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.control))
        }
    }

    /// "Which Files" opened: each file and what it sends.
    private var filesList: some View {
        VStack(alignment: .leading, spacing: 5) {
            label("\(card.plan.files.count) not answered before")
            ForEach(card.plan.files) { file in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(file.name).scaledFont(.callout).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(Self.status(file.status)).scaledFont(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .foregroundStyle(file.status == .needsOK ? ChromeInk.bodyText(colorScheme, SemanticColor.warning) : Color.secondary)
                        .background((file.status == .needsOK ? SemanticColor.warning : Color.secondary).opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private static func status(_ status: FileSyncManager.FilingRefinePlanFile.Status) -> String {
        switch status {
        case .namePlusPage: "name + first page"
        case .nameOnly: "name only"
        case .needsOK: "needs your OK"
        case .nextPress: "next Refine"
        }
    }

    private var monthRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(card.monthLine).scaledFont(.footnote).foregroundStyle(.secondary)
                if card.plan.routesToClaude { AskClaudeInfoMark(text: AskClaudeRefineCard.monthInfo) }
            }
            if card.plan.routesToClaude, let fraction = card.monthFraction {
                ProgressView(value: fraction).progressViewStyle(.linear)
            }
        }
    }

    private var planButtons: some View {
        // Side by side when they fit; stacked, right-aligned, at the panel's narrowest.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) { Spacer(minLength: 0); planActions }
            VStack(alignment: .trailing, spacing: 6) { planActions }
        }
        .controlSize(.small)
        .padding(.top, 2)
    }

    @ViewBuilder private var planActions: some View {
        Button("Cancel") { bridge.cancel(itemID) }
        if card.layout == .overLimit {
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

    private var sending: some View {
        VStack(alignment: .leading, spacing: 9) {
            heading(card.sendingTitle)
            if card.plan.downloads > 0 {
                Text("\(card.plan.downloads) cloud-only \(card.plan.downloads == 1 ? "file" : "files") downloaded to read page 1")
                    .scaledFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(card.progressLine(elapsed: card.startedAt.map { max(0, Int(context.date.timeIntervalSince($0))) }))
                            .fixedSize(horizontal: false, vertical: true)
                        AskClaudeInfoMark(text: AskClaudeRefineCard.sendingInfo)
                    }
                    .scaledFont(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("Stop") { bridge.stop(itemID) }.controlSize(.small)
            }
        }
    }

    // MARK: After

    @ViewBuilder private var done: some View {
        if let answers = card.answers {
            if let title = card.endingTitle {
                heading(title, symbol: "exclamationmark.triangle", tint: ChromeInk.bodyText(colorScheme, SemanticColor.warning))
                if let message = card.endingMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                        if let info = card.endingInfo { AskClaudeInfoMark(text: info) }
                    }
                    .scaledFont(.callout)
                }
            } else {
                heading(card.answersTitle, symbol: "checkmark.circle")
                if let sub = card.answersSub {
                    Text(sub).scaledFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !answers.rows.isEmpty { rows(answers) }
            if card.endingTitle == nil, let foot = card.answersFootnote {
                Text(foot).scaledFont(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let waiting = card.answersWaitingNote { note(waiting, info: AskClaudeRefineCard.answersWaitingInfo) }
            if answers.undone {
                Label("Undone. The on-device suggestions are back.", systemImage: "arrow.uturn.backward")
                    .scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let receipt = card.receiptInfo {
                        HStack(spacing: 4) { Text("Receipt"); AskClaudeInfoMark(text: receipt) }
                            .scaledFont(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if bridge.canUndo(itemID) { Button("Undo Refine") { bridge.undo(itemID) } }
                    if let retry = card.retryTitle {
                        Button(retry) { bridge.retry(itemID) }.buttonStyle(.borderedProminent).accentedProminent()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder private func rows(_ answers: AskClaudeRefineCard.Answers) -> some View {
        let shown = showsAll ? answers.rows : Array(answers.rows.prefix(AskClaudeRefineCard.rowsShown))
        VStack(alignment: .leading, spacing: 7) {
            ForEach(shown) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Button(row.name) { bridge.reveal(row.path) }
                        .buttonStyle(.link).scaledFont(.callout)
                    (Text((row.before.map { "\($0) → " } ?? "No folder → ")).foregroundStyle(.secondary)
                        + Text(row.after).fontWeight(.semibold))
                        .scaledFont(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = row.reason, !reason.isEmpty {
                        Text(reason).scaledFont(.footnote).italic().foregroundStyle(.secondary)
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
