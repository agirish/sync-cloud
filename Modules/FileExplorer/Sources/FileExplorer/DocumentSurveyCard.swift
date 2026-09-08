import SwiftUI
import Design

/// What the document survey card is showing on Organize's overview.
///
/// **Plain values, no `Sync` types — the same rule `OrganizeOverview` already follows** for
/// `reclaimable` and `scopeFolders`. That file imports SwiftUI and Design and nothing else, so the
/// caller does the translating; what arrives here is counts, seconds and one already-worded pause
/// sentence. It keeps the card testable without a manager, and keeps the domain out of a view.
public enum DocumentSurveyCardState: Equatable, Sendable {

    /// Never read here.
    ///
    /// **The only state with a cost sentence**, because it is the only one asking for a decision:
    /// three hours is a real ask, and the card that makes it has to say so before the button.
    ///
    /// `documents` is **optional, and nil is the ordinary first case.** Knowing how many would be
    /// read means walking the whole tree, which is not something to do every time somebody opens
    /// Organize — and the numbers lying around are the wrong ones: summing the profile's
    /// `fileCount` counts every file, which on the reference tree is 11,835 against the 11,019 the
    /// survey would actually open. A card that promised the larger number would be overstating the
    /// work by 7% in the one sentence a person uses to decide. So it says how long without saying
    /// how many, and the count appears the moment the walk has really been done.
    case offered(documents: Int?)

    /// Reading, or paused while reading. `pause` nil means actively reading.
    case running(done: Int, total: Int, folder: String?,
                 secondsRemaining: TimeInterval?, pause: PauseNote?)

    /// Every document decided; merging, rebuilding the memory and writing.
    ///
    /// **Its own state, because rendering it as a pause said something false.** It was first mapped
    /// onto a `PauseNote`, which made the card read "Reading documents · paused at 7,558 of 7,558 …
    /// Resumes on its own" — over a survey that was not paused, could not be resumed, and was doing
    /// the last and least interruptible minutes of its work. It also offered a Pause for something
    /// with nothing to pause.
    case finishing(done: Int)

    /// Stopped with progress on disk — RD11 decision 3.
    ///
    /// **The card that never starts anything.** The offer card promises "nothing starts it but a
    /// click", and a survey that resumed itself at the next launch would make that sentence false.
    /// So this waits, and it says how little is left rather than restating the original three-hour
    /// ask: "4,687 to go" is a much easier second decision than the first one was.
    case interrupted(done: Int, total: Int)

    /// Just finished. `summary` is the sentence the survey itself composed.
    case finished(summary: String, unreadableTypes: Int)

    /// Read, and settled — the standing state of a tree whose documents are already in the corpus.
    ///
    /// **The state this card was missing, and the omission left the feature with no front door.**
    /// Once a memory existed the card vanished entirely, so Organize's overview said nothing about
    /// the reading at all: the "surveyed 3 days ago" line lived on Restructure's card, and the
    /// refresh was an item inside a dropdown on To File's rescan button. Three places, none of them
    /// where somebody would look, and nothing to say the reading had ever happened.
    ///
    /// Shaped as **Storage's receipt** — provenance and its verb, no badge, no count pill — which
    /// is the pattern this screen already has for "an answer you asked for, with nothing to do
    /// about it". `lastRead` is nil for a corpus written before the stamp existed, or by the
    /// offline builder; the card then states what it knows and skips what it does not.
    case settled(folders: Int, lastRead: Date?)

    /// A pause, worded by the caller.
    ///
    /// `resumesOnItsOwn` is what decides the verb — *Resumes on its own · Resume now* against a
    /// plain *Resume* — and it is a boolean rather than being inferred from the sentence, because
    /// inferring it would be the view parsing the app's own copy.
    public struct PauseNote: Equatable, Sendable {
        public let sentence: String
        public let resumesOnItsOwn: Bool
        public init(sentence: String, resumesOnItsOwn: Bool) {
            self.sentence = sentence
            self.resumesOnItsOwn = resumesOnItsOwn
        }
    }
}

/// The card's words, as static functions so they can be read by a test without mounting a view.
///
/// The same shape `OrganizeOverview.Ledger.meterCaption` uses, and for the same reason: what this
/// screen *says* has been wrong more often than what it draws.
public enum DocumentSurveyCardText {

    /// Whole hours and minutes — never seconds, and never a decimal.
    ///
    /// **"About" is doing real work in front of it.** The estimate is a rate over a serial read of
    /// wildly uneven documents, and a card reading "1 h 47 min left" claims a precision the number
    /// does not have. Rounded to five minutes above an hour for the same reason: a figure that
    /// ticks 1 h 50 → 1 h 49 → 1 h 48 invites someone to watch it.
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
            return "Read \(done.formatted()) documents · learning from them"
        case .interrupted(let done, let total):
            guard done < total else { return "Documents read — not saved yet" }
            return "Reading documents — paused at \(done.formatted()) of \(total.formatted())"
        case .finished:
            return "Documents read"
        case .settled:
            return "Documents read"
        }
    }

    /// The line under the title.
    ///
    /// **The offer's version says what it costs before it says what it buys**, which is the
    /// opposite of how a feature usually introduces itself and is right here: three hours of
    /// background reading is the thing a person needs to weigh, and burying it under the benefit
    /// would be selling rather than offering.
    public static func detail(for state: DocumentSurveyCardState) -> String {
        switch state {
        case .offered(let documents):
            let opening = "Reading page one of every document lets To File and Restructure use "
                + "what a file says, not only what it is named. "
            guard let documents else {
                return opening + "It runs in the background over a few hours and can be paused. "
                    + "It counts the documents first and says how many before it opens any."
            }
            return opening + "About 3 h for \(documents.formatted()) documents, in the "
                + "background. Pausable; only new documents are read next time."
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
            // **Everything read, nothing written.** Reached when the corpus write fails after a
            // complete pass: the checkpoint is kept, so the remainder is zero and the work left is
            // the write. "0 still to read — carrying on opens only those" was the sentence that
            // produced, which reads as a bug rather than as the retry it is offering.
            guard left > 0 else {
                return "Every document was read; what was learned still has to be saved. "
                    + "Carrying on saves it without re-reading anything."
            }
            return "Stopped when you quit. \(left.formatted()) still to read — carrying on opens "
                + "only those."
        case .settled(let folders, let lastRead):
            // The VERB agrees too: "1 folder has", "2 folders have". Pluralising the noun and
            // leaving the verb alone produced "1 folder have learned content", which is the shape
            // a one-folder first survey would actually have shown.
            var parts = [folders == 1 ? "1 folder has learned content"
                                      : "\(folders.formatted()) folders have learned content"]
            // `RestructureLens`' phrasing, not a second one: "today", "yesterday", "3 days ago" is
            // already how this app says when a survey happened, and two vocabularies for one fact
            // is how they drift.
            if let lastRead {
                parts.append("read \(RestructureLens.surveyedPhrase(lastRead, now: Date()))")
            }
            return parts.joined(separator: " · ") + ". Refreshing reads only what has changed since."
        case .finished(let summary, let unreadableTypes):
            guard unreadableTypes > 0 else { return summary }
            // **Named, not folded into the read count.** A summary that reports only what it
            // managed reads as complete when it was not, and these are the largest single gap in a
            // derived survey — 816 of 11,835 on the reference tree, leaving 143 folders with no
            // content at all.
            return summary + " \(unreadableTypes.formatted()) Word, PowerPoint and Excel documents "
                + "were not read — this app cannot open them."
        }
    }

    /// How far along, or nil where a bar would be a claim rather than a fact.
    ///
    /// The offer has no fraction because nothing has happened; the completion has none because a
    /// full bar under "Documents read" is a second way of saying the same thing.
    public static func fraction(for state: DocumentSurveyCardState) -> Double? {
        switch state {
        case .offered, .finished, .finishing, .settled:
            // Finishing has no fraction of its own: the reading is done, and a full bar under it
            // would be counting something that has stopped counting.
            return nil
        case .running(let done, let total, _, _, _), .interrupted(let done, let total):
            guard total > 0 else { return nil }
            return min(1, max(0, Double(done) / Double(total)))
        }
    }
}

/// The document survey's card: the offer, the run, the pause, the interruption and the receipt.
///
/// **One card through every state rather than four**, and that is the point of it: a survey that
/// changed shape as it went would make "paused" and "stalled" look like different things happening
/// in different places. What moves between states is the words, the bar and the verb.
///
/// **It never carries a count badge, and it is outside the checks-run fraction.** That answers
/// ROADMAP_V5's open question and needs no ledger code: `countedLenses` filters `OrganizeLens`
/// cases on `carriesBadge` plus a producing pass, and the survey is neither a lens nor a pass, so
/// it falls out exactly as Storage does. A badge means something to act on, and reading is not that.
struct DocumentSurveyCard: View {

    let state: DocumentSurveyCardState
    let accent: Color

    /// Starts a first survey. nil hides the verb — a host that cannot run one gets a card that
    /// states the position rather than a button that does nothing, the same rule
    /// `onBuildStorage` and `onUpdateFolderMemory` follow.
    var onStart: (() -> Void)?
    var onResume: (() -> Void)?
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    /// Opens Help at *Reading your documents*. Same shape as `RestructureLens.helpPointer`, down to
    /// the glyph.
    var onOpenHelp: (() -> Void)?
    /// Runs the incremental re-survey — the existing *Refresh what’s learned* pass. nil hides the
    /// verb, the same rule the other four follow.
    var onUpdate: (() -> Void)?

    var body: some View {
        OverviewCard(
            symbol: "doc.text.magnifyingglass",
            title: DocumentSurveyCardText.title(for: state),
            subtitle: DocumentSurveyCardText.detail(for: state),
            accent: accent,
            actions: verbs,
            // **The claim stays through every state.** A privacy line that appeared only on the
            // offer card would read as a sales line rather than a fact about the feature — and the
            // state where a person is most likely to wonder is the one where they can see it
            // working.
            //
            // Scoped to the reading, exactly as the Help article is: "on this Mac" is true of this
            // feature without qualification, while an app-wide claim would not be — Refine with
            // Claude reaches Anthropic's API with the user's own key.
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

    /// **Grey while paused, accent while reading.** The pair has to be drawn together: a paused
    /// survey that looked identical to a running one would be a count that stopped moving, which
    /// reads as a hang — and the honest response to a hang is force-quitting an app that is fine.
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
        // **`designAnimation`, not `.animation`.** Every animated change in this app goes through
        // it so Reduce Motion turns the movement off rather than slowing it down, and
        // `ReduceMotionCoverageScanTests` scans the whole app for raw sites. A survey's bar is
        // exactly the sort of continuous motion somebody switches Reduce Motion on to be rid of —
        // it moves for three hours.
        .designAnimation(.easeOut(duration: 0.2), value: fraction)
    }

    /// The card's verbs, as ``OverviewCardAction`` values rather than buttons.
    ///
    /// **The ranks are what changed, and they are the whole point of stating them as data.** This
    /// card used to pick its own dresses per state — a prominent Start, a bordered Pause, a
    /// bordered "Resume now", and, in the settled state, a bare accent word that was the only
    /// control on the overview with no button shape at all. That last one sat at a card's
    /// top-right beside a Storage receipt whose verbs were also bare accent words, above a
    /// Restructure card whose Refresh was a *bordered* button 60pt lower and 400pt to the left.
    /// One word, three appearances, three positions.
    ///
    /// Now: whatever this card's most important verb is in the state it is in is the primary, it is
    /// the rightmost control, and it looks exactly like every other card's primary.
    var verbs: [OverviewCardAction] {
        switch state {
        case .offered:
            return onStart.map {
                [OverviewCardAction(title: "Read my documents", rank: .primary, run: $0)]
            } ?? []
        case .running(_, _, _, _, let pause):
            // **Stop is listed first, and that is not cosmetic.** `drawingOrder` moves a primary to
            // the end, so a state that HAS one already put Stop on the left; the auto-resume state
            // has none — "Resume now" is deliberately the quieter of the two, an impatience valve
            // rather than the way out — and listing Stop last there left the one destructive verb
            // on this page sitting in the slot the whole layout reserves for a card's main verb.
            // Listing it first is correct in every state and depends on no other rule holding.
            var actions: [OverviewCardAction] = []
            if let onStop {
                actions.append(OverviewCardAction(title: "Stop", run: onStop))
            }
            if let pause, !pause.resumesOnItsOwn, let onResume {
                actions.append(OverviewCardAction(title: "Resume", rank: .primary, run: onResume))
            } else if pause == nil, let onPause {
                actions.append(OverviewCardAction(title: "Pause", rank: .primary, run: onPause))
            } else if pause != nil, let onResume {
                actions.append(OverviewCardAction(title: "Resume now", run: onResume))
            }
            return actions
        case .interrupted:
            var actions: [OverviewCardAction] = []
            if let onResume {
                actions.append(OverviewCardAction(title: "Resume", rank: .primary, run: onResume))
            }
            if let onStart {
                // "Start over" rather than "Start": the distinction matters here, where a
                // partly-finished survey is on disk and the alternative throws it away.
                actions.append(OverviewCardAction(title: "Start over", run: onStart))
            }
            return actions
        case .finished, .finishing:
            // Nothing to offer: the reading is over, and the merge cannot be paused or stopped
            // without throwing away the whole pass.
            return []
        case .settled:
            // **Refresh, not "Read again".** This runs the incremental pass — new and changed
            // documents only, seconds to minutes — which is the refresh anybody actually wants.
            // A full re-read is three hours and a genuinely different need (a suspect corpus,
            // changed extraction rules); offering it beside a thirty-second button would invite
            // the wrong click, so it is deliberately not here.
            return onUpdate.map {
                [OverviewCardAction(title: "Refresh", rank: .primary,
                                    help: "Reads only the documents that changed since the last "
                                        + "survey.", run: $0)]
            } ?? []
        }
    }

    /// Long on the offer, short everywhere else — the offer is where the decision is made, and the
    /// running card should not spend three lines re-arguing something already agreed.
    private var privacySentence: String {
        if case .offered = state {
            return "Everything happens on this Mac. Nothing is uploaded, and nothing is reported to anyone."
        }
        return "On this Mac · no network"
    }
}
