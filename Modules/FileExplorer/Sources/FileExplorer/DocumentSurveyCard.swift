import AppKit
import SwiftUI
import Design

/// What the document survey card is showing on Organize's overview.
///
/// Plain values, no `Sync` types, as `OrganizeOverview` does for `reclaimable` and
/// `scopeFolders`: the caller translates into counts, seconds and an already-worded pause
/// sentence, so the card is testable without a manager.
public enum DocumentSurveyCardState: Equatable, Sendable {

    /// Never read here. The only state with a cost sentence, because it is the only one asking
    /// for a decision, and hours of reading must be stated before the button.
    ///
    /// `documents` is nil in the ordinary first case: counting means walking the whole tree, and
    /// the profile's `fileCount` counts every file, overstating the work. So the card says how
    /// long without how many until the walk is done.
    case offered(documents: Int?)

    /// Reading, or paused while reading. `pause` nil means actively reading.
    case running(done: Int, total: Int, folder: String?,
                 secondsRemaining: TimeInterval?, pause: PauseNote?)

    /// Every document decided; merging, rebuilding the memory and writing. Its own state, not a
    /// pause: it can't be paused or resumed, so a pause's words and Pause verb would be false.
    case finishing(done: Int)

    /// Stopped with progress on disk. It never resumes by itself, because the offer promises
    /// nothing starts but a click; it waits, saying how little is left rather than restating the
    /// original ask.
    case interrupted(done: Int, total: Int)

    /// Just finished. `summary` is the sentence the survey itself composed.
    case finished(summary: String, unreadableTypes: Int)

    /// Read, and settled: the standing state of a tree whose documents are already in the corpus.
    /// It keeps the reading visible on the overview, with its refresh, once a memory exists.
    ///
    /// Shaped as Storage's receipt: provenance and its verb, no badge, no count pill. `lastRead` is
    /// nil for a corpus written without the stamp (older, or by the offline builder); the card
    /// then skips the date.
    case settled(folders: Int, lastRead: Date?)

    /// A pause, worded by the caller.
    ///
    /// `resumesOnItsOwn` decides the verb (*Resumes on its own · Resume now* or plain *Resume*). A
    /// Bool, so the view never parses the app's own copy.
    public struct PauseNote: Equatable, Sendable {
        public let sentence: String
        public let resumesOnItsOwn: Bool
        public init(sentence: String, resumesOnItsOwn: Bool) {
            self.sentence = sentence
            self.resumesOnItsOwn = resumesOnItsOwn
        }
    }
}

/// The card's words, as static functions a test can read without mounting a view, like
/// `OrganizeOverview.Ledger.meterCaption`.
public enum DocumentSurveyCardText {

    /// Whole hours and minutes, never seconds or decimals. "About", and five-minute steps above an
    /// hour, because the rate over uneven documents is rough, and a figure that ticks every minute
    /// invites watching.
    public static func remaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "under a minute left" }
        let minutes = total / 60
        if minutes < 60 { return "about \(minutes) min left" }
        let hours = minutes / 60
        let rest = ((minutes % 60) / 5) * 5
        return rest == 0 ? "about \(hours) h left" : "about \(hours) h \(rest) min left"
    }

    public static func title(for state: DocumentSurveyCardState) -> String {
        switch state {
        case .offered:
            return "Documents — not yet read"
        case .running(let done, let total, _, _, let pause):
            let counted = "\(done.formatted()) of \(total.formatted())"
            return pause == nil ? "Reading documents · \(counted)"
                                : "Reading documents · paused at \(counted)"
        case .finishing(let done):
            return done == 1 ? "Read 1 document · learning from it"
                : "Read \(done.formatted()) documents · learning from them"
        case .interrupted(let done, let total):
            guard done < total else { return "Documents read — not saved yet" }
            return "Reading documents — paused at \(done.formatted()) of \(total.formatted())"
        case .finished:
            return "Documents read"
        case .settled:
            return "Documents read"
        }
    }

    /// The line under the title. The offer's version names the benefit, then the cost, hours of
    /// background reading, before the button.
    public static func detail(for state: DocumentSurveyCardState) -> String {
        switch state {
        case .offered(let documents):
            let opening = "Reading page one of every document lets To File and Restructure use "
                + "what a file says, not only what it is named. "
            guard let documents else {
                return opening + "It runs in the background over a few hours and can be paused. "
                    + "It counts the documents first and says how many before it opens any."
            }
            // A walk that found nothing to read offers no read: the card says so, and offers to
            // look again once some are added.
            guard documents > 0 else {
                return opening + "No document here is in a format this app can open, so there is "
                    + "nothing to read yet."
            }
            // The figure lives in ``DocumentSurveyCost``, shared with setup's Structure screen,
            // so one number isn't worded twice.
            return opening + DocumentSurveyCost.offerClause(documents: documents)
                + " Pausable; only new documents are read next time."
        case .running(_, _, let folder, let seconds, let pause):
            if let pause {
                return pause.resumesOnItsOwn ? "\(pause.sentence) Resumes on its own."
                                             : pause.sentence
            }
            let eta = seconds.map(remaining) ?? "working out how long this will take"
            return folder.map { "\(eta) · reading \($0)" } ?? eta
        case .finishing:
            return "Working out what each folder has learned from them. A minute or two, and "
                + "nothing to do."
        case .interrupted(let done, let total):
            let left = max(0, total - done)
            // Everything read, nothing written: the corpus write failed after a complete pass, so
            // nothing is left to read and the retry is the write. "0 still to read" would read as
            // a bug.
            guard left > 0 else {
                return "Every document was read; what was learned still has to be saved. "
                    + "Carrying on saves it without re-reading anything."
            }
            return "Stopped when you quit. \(left.formatted()) still to read — carrying on opens "
                + "only those."
        case .settled(let folders, let lastRead):
            // The verb agrees too: "1 folder has", "2 folders have".
            var parts = [folders == 1 ? "1 folder has learned content"
                                      : "\(folders.formatted()) folders have learned content"]
            // `RestructureLens`' phrasing ("today", "3 days ago"), so one fact has one vocabulary.
            if let lastRead {
                parts.append("read \(RestructureLens.surveyedPhrase(lastRead, now: Date()))")
            }
            return parts.joined(separator: " · ") + ". Refreshing reads only what has changed since."
        case .finished(let summary, let unreadableTypes):
            guard unreadableTypes > 0 else { return summary }
            // Named, not folded into the read count: a summary of only what it managed reads as
            // complete, and these are a survey's largest gap, leaving whole folders unread.
            return summary + (unreadableTypes == 1
                ? " 1 Word, PowerPoint or Excel document was not read — this app cannot open it."
                : " \(unreadableTypes.formatted()) Word, PowerPoint and Excel documents "
                    + "were not read — this app cannot open them.")
        }
    }

    /// How far along, or nil where a bar would claim rather than measure: nothing has happened yet
    /// on the offer, and a full bar under "Documents read" says nothing new.
    public static func fraction(for state: DocumentSurveyCardState) -> Double? {
        switch state {
        case .offered, .finished, .finishing, .settled:
            // Finishing has none either: the reading is done and the count has stopped.
            return nil
        case .running(let done, let total, _, _, _), .interrupted(let done, let total):
            guard total > 0 else { return nil }
            return min(1, max(0, Double(done) / Double(total)))
        }
    }
}

/// The document survey's card: the offer, the run, the pause, the interruption and the receipt.
///
/// One card through every state, so a run never changes shape; only the words, bar and verbs
/// move.
///
/// No count badge, and outside the checks-run fraction: `countedLenses` counts `OrganizeLens`
/// cases with `carriesBadge` and a producing pass, and the survey is neither, like Storage. A badge
/// means something to act on, and reading isn't that.
struct DocumentSurveyCard: View {

    let state: DocumentSurveyCardState
    let accent: Color

    /// Starts a first survey. nil hides the verb rather than drawing a button that does nothing,
    /// as `onBuildStorage` and `onUpdateFolderMemory` do.
    var onStart: (() -> Void)?
    /// The interrupted card's *Start over*: discards the progress on disk, then starts. Not
    /// `onStart`, which adopts that progress and would resume instead. nil hides the verb.
    var onStartOver: (() -> Void)?
    var onResume: (() -> Void)?
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    /// Opens Help at *Reading your documents*, shaped like `RestructureLens.helpPointer`.
    var onOpenHelp: (() -> Void)?
    /// Runs the incremental re-survey, the *Refresh what’s learned* pass. nil hides the verb.
    var onUpdate: (() -> Void)?
    /// Asks before *Start over* throws the reading away: the alert in the app, a canned answer in
    /// a test. Its arguments are the card's `done` and `total`.
    var confirmStartOver: @MainActor (_ done: Int, _ total: Int) -> Bool = { done, total in
        DocumentSurveyCard.startOverAlert(done: done, total: total).runModal() == .alertFirstButtonReturn
    }

    /// Asked, because the click throws away hours of reading that Resume would keep.
    ///
    /// The leave questions' shape: the destructive answer first, off Return, then Cancel, which
    /// keeps the Esc AppKit gives a button of that name, so no keypress starts over.
    static func startOverAlert(done: Int, total: Int) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Start over and read every document again?"
        let read = done == 1 ? "1 document" : "\(done.formatted()) documents"
        alert.informativeText = "The \(read) read so far will be read again, from the first of "
            + "\(total.formatted()). Resume carries on from where it stopped instead."
        alert.addButton(withTitle: "Start Over")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[0].hasDestructiveAction = true
        return alert
    }

    var body: some View {
        OverviewCard(
            symbol: "doc.text.magnifyingglass",
            title: DocumentSurveyCardText.title(for: state),
            subtitle: DocumentSurveyCardText.detail(for: state),
            accent: accent,
            actions: verbs,
            // The privacy line stays through every state: shown only on the offer it would read
            // as a sales line, and people wonder most while it is running.
            //
            // Scoped to the reading, as the Help article is: an app-wide claim would be false,
            // because Refine with Claude reaches Anthropic's API with the user's own key.
            note: OverviewCardNote(
                privacySentence, symbol: "lock.fill", help: onOpenHelp,
                helpLabel: "About reading your documents",
                helpTip: "What gets opened, how much is read, what is kept — and why none of it "
                    + "leaves this Mac.")) {
            if let fraction = DocumentSurveyCardText.fraction(for: state) {
                progressBar(fraction)
            }
        }
    }

    /// Grey while paused, accent while reading: a paused bar that looked like a running one would
    /// read as a hang.
    @ViewBuilder
    private func progressBar(_ fraction: Double) -> some View {
        let paused: Bool = {
            if case .running(_, _, _, _, let pause) = state { return pause != nil }
            if case .interrupted = state { return true }
            return false
        }()
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))
                    .frame(width: max(0, geometry.size.width * fraction))
            }
        }
        .frame(height: 5)
        .frame(maxWidth: 260)
        // `designAnimation`, not `.animation`, so Reduce Motion turns the movement off;
        // `ReduceMotionCoverageScanTests` scans for raw sites.
        .designAnimation(.easeOut(duration: 0.2), value: fraction)
    }

    /// *Resume now*'s tooltip, shared with the strip so the two say the same thing.
    static let resumeNowHelp = "Read now instead of waiting — it still pauses for anything new"

    /// The card's verbs, as ``OverviewCardAction`` values rather than buttons, so `OverviewCard`
    /// dresses and places them. The state's most important verb is the primary: the rightmost
    /// control, looking like every other card's primary.
    var verbs: [OverviewCardAction] {
        switch state {
        case .offered(.some(0)):
            // Nothing to read, so the offer is the same walk, asked again after documents are
            // added.
            return onStart.map {
                [OverviewCardAction(title: "Look Again", rank: .primary,
                                    help: "Count the documents here again — for after you add some "
                                        + "this app can open", run: $0)]
            } ?? []
        case .offered:
            return onStart.map {
                [OverviewCardAction(title: "Read My Documents", rank: .primary,
                                    help: "Read page one of every document here, on this Mac — in the "
                                        + "background, and it can be paused", run: $0)]
            } ?? []
        case .running(_, _, _, _, let pause):
            // Stop is listed first. `drawingOrder` moves a primary to the end, but the auto-resume
            // state has none ("Resume now" is deliberately quiet), and listing Stop last there
            // would put the destructive verb in the slot for a card's main verb.
            var actions: [OverviewCardAction] = []
            if let onStop {
                actions.append(OverviewCardAction(title: "Stop",
                                                  help: "Stop reading — what’s been read so far is kept",
                                                  run: onStop))
            }
            if let pause, !pause.resumesOnItsOwn, let onResume {
                actions.append(OverviewCardAction(title: "Resume", rank: .primary, run: onResume))
            } else if pause == nil, let onPause {
                actions.append(OverviewCardAction(title: "Pause", rank: .primary, run: onPause))
            } else if pause != nil, let onResume {
                actions.append(OverviewCardAction(title: "Resume Now", help: Self.resumeNowHelp,
                                                  run: onResume))
            }
            return actions
        case .interrupted(let done, let total):
            var actions: [OverviewCardAction] = []
            if let onResume {
                actions.append(OverviewCardAction(title: "Resume", rank: .primary,
                                                  help: "Carry on reading — only the documents not yet read",
                                                  run: onResume))
            }
            if let onStartOver {
                // "Start over", not "Start": it throws away a partly-finished survey, so it asks
                // first and only a yes reaches the verb that discards it.
                let confirm = confirmStartOver
                actions.append(OverviewCardAction(
                    title: "Start Over",
                    help: "Forget what’s been read and read every document again, from the first",
                    run: { if confirm(done, total) { onStartOver() } }))
            }
            return actions
        case .finished, .finishing:
            // Nothing to offer: the reading is over, and stopping the merge would throw away the
            // whole pass.
            return []
        case .settled:
            // Refresh, not "Read again": the incremental pass, new and changed documents only. A
            // full re-read takes hours and is a different need, so it is deliberately not offered
            // beside it.
            return onUpdate.map {
                [OverviewCardAction(title: "Refresh", rank: .primary,
                                    help: "Reads only the documents that changed since the last "
                                        + "survey.", run: $0)]
            } ?? []
        }
    }

    /// Long on the offer, where the decision is made; short everywhere else.
    private var privacySentence: String {
        if case .offered = state {
            return "Everything happens on this Mac. Nothing is uploaded, and nothing is reported to anyone."
        }
        return "On this Mac · no network"
    }
}
