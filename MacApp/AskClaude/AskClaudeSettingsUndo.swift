import Foundation
import Settings
import Sync

/// Which change a setting's value came from: a new token every time the value is seen to have
/// moved, whoever moved it (a card, Settings, the View menu, the toolbar, a reset).
///
/// Compared when asked, not watched: only a card's writes come through the chat, so the ledger
/// compares the live value on every draw of a card, and a value that differs from the last one it
/// saw gets a fresh token. A card holding the current token made the latest change; one that
/// doesn't offers no Undo. A change and a change back while no card was drawn look like no change.
/// Tokens last for the session: a card restored after a relaunch holds none, and offers no Undo.
@MainActor
final class AskClaudeSettingsLedger {
    struct Key: Hashable {
        let id: String
        let target: String?
    }

    private var seen: [Key: (value: SettingValue?, token: UUID)] = [:]

    /// The token of the value `read` gives now, new if the value moved since the last look.
    func token(_ key: Key, value: SettingValue?) -> UUID {
        if let last = seen[key], last.value == value { return last.token }
        let token = UUID()
        seen[key] = (value, token)
        return token
    }

    /// An undo's own write: the value it put back is the one an earlier step made, so that step's
    /// token comes back with it, and a second Undo can reach it.
    func restore(_ key: Key, value: SettingValue, token: UUID) {
        seen[key] = (value, token)
    }
}

/// One change a card made, undoable: the setting, what it was and what it became, and the token
/// of that change. Apply All's several rows are one step.
struct AskClaudeSettingsStep {
    struct Change {
        let key: AskClaudeSettingsLedger.Key
        let before: SettingValue
        let after: SettingValue
        var token: UUID
        /// The token `before` had: an earlier step's, when one made it, so an Undo that writes
        /// `before` back makes that step the latest again.
        var beforeToken = UUID()
    }

    let card: UUID
    let rows: [Int]
    var changes: [Change]
    /// When it was made, so a pinned panel's ⌘Z takes the newest of this and typing first.
    var recordedAt = Date()
    /// "Theme", or the card's title for several.
    let name: String
    /// Undoing it would raise Claude's spending or access, so only the card's own Undo — badged —
    /// takes it back; ⌘Z passes over it and can't quietly turn reading back on.
    let cardOnly: Bool
    /// Redoing it would raise, so ⇧⌘Z passes over it too: the change came from a click, and only a
    /// click makes it again.
    var redoRaises = false
}

/// The chat's own undo and redo of settings changes, separate from typing's so it survives the
/// panel: the panel's window and its undo manager are torn down whenever the panel closes or steps
/// aside for Settings. The chat owns these for as long as it lives; New Chat clears them with the
/// cards they belong to. The panel window sends Undo here when no draft is being typed
/// (`AskClaudePanelWindow`).
@MainActor
final class AskClaudeSettingsUndo {
    private(set) var undoSteps: [AskClaudeSettingsStep] = []
    private(set) var redoSteps: [AskClaudeSettingsStep] = []

    /// Reads a setting's live value, and writes one; set by the app.
    var read: (_ key: AskClaudeSettingsLedger.Key) -> SettingValue? = { _ in nil }
    var write: (_ key: AskClaudeSettingsLedger.Key, _ value: SettingValue) -> Bool = { _, _ in false }
    /// Tells the chat what a step did, for its card and for Claude.
    var didStep: (_ step: AskClaudeSettingsStep, _ undone: Bool) -> Void = { _, _ in }
    let ledger = AskClaudeSettingsLedger()

    /// The current token of `key`'s value.
    func token(_ key: AskClaudeSettingsLedger.Key) -> UUID { ledger.token(key, value: read(key)) }

    /// Refused while undoing or redoing — the write came back no — with the step kept where it was.
    var didRefuse: (_ step: AskClaudeSettingsStep) -> Void = { _ in }

    /// Records a change a card just made. Where an earlier step made the value this one changed,
    /// that step's token is this one's way back.
    func record(_ step: AskClaudeSettingsStep) {
        var step = step
        for (index, change) in step.changes.enumerated() {
            if let earlier = undoSteps.last(where: { $0.changes.contains { $0.key == change.key } })?
                .changes.first(where: { $0.key == change.key }), earlier.after == change.before {
                step.changes[index].beforeToken = earlier.token
            }
        }
        undoSteps.append(step)
        redoSteps.removeAll()
    }

    /// The changes Claude made itself, once their card is in the chat as `card`:
    /// a step per row, as a click on it would have made, so Undo and Edit ▸ Undo take them back.
    func recordClaude(_ rows: [AskClaudeSettingCard.Row], card: UUID) {
        for (index, row) in rows.enumerated() where row.byClaude == true {
            let key = AskClaudeSettingsLedger.Key(id: row.id, target: row.target)
            guard let entry = SettingsCatalog.entry(row.id), let was = row.changedFrom, let after = read(key),
                  let before = SettingsCatalog.value(was, for: entry) ?? AskClaudeSettingCardView.storedValue(was, like: after),
                  before != after else { continue }
            record(AskClaudeSettingsStep(
                card: card, rows: [index], changes: [.init(key: key, before: before, after: after, token: token(key))],
                name: entry.label, cardOnly: entry.raises(from: after, to: before)))
        }
    }

    /// A setting whose write lands only once something else catches up: a source's name, path
    /// and Open at take effect when the sources are discovered again. An undo of one reads the old
    /// value straight after writing, so its token names that; once the value it wrote is there, its
    /// steps take that value's token again.
    func resettle(_ key: AskClaudeSettingsLedger.Key) {
        let now = read(key)
        for index in undoSteps.indices {
            for (row, change) in undoSteps[index].changes.enumerated() where change.key == key && now == change.after {
                undoSteps[index].changes[row].token = token(key)
            }
        }
        for index in redoSteps.indices {
            for (row, change) in redoSteps[index].changes.enumerated() where change.key == key && now == change.before {
                redoSteps[index].changes[row].token = token(key)
            }
        }
    }

    /// Whether `step` still describes the live values: nothing changed any of them since.
    func isCurrent(_ step: AskClaudeSettingsStep) -> Bool {
        step.changes.allSatisfy { token($0.key) == $0.token }
    }

    /// The newest step ⌘Z may take: still current (an undo never overwrites something newer), and
    /// not one only its card's Undo takes back — or, for ⇧⌘Z, one whose redo would raise.
    private func menuIndex(in steps: [AskClaudeSettingsStep], redoing: Bool = false) -> Int? {
        steps.indices.reversed().first { index in
            let step = steps[index]
            return !(redoing ? step.redoRaises : step.cardOnly) && isCurrent(step)
        }
    }

    var canUndo: Bool { menuIndex(in: undoSteps) != nil }
    var canRedo: Bool { menuIndex(in: redoSteps, redoing: true) != nil }
    var undoTitle: String? { menuIndex(in: undoSteps).map { "Undo \(undoSteps[$0].name)" } }
    var redoTitle: String? { menuIndex(in: redoSteps, redoing: true).map { "Redo \(redoSteps[$0].name)" } }

    /// Edit ▸ Undo and ⌘Z.
    func undo() {
        guard let index = menuIndex(in: undoSteps) else { return }
        let step = undoSteps.remove(at: index)
        guard let done = apply(step, undoing: true) else {
            undoSteps.insert(step, at: index)
            didRefuse(step)
            return
        }
        redoSteps.append(done)
        didStep(done, true)
    }

    /// Edit ▸ Redo and ⇧⌘Z.
    func redo() {
        guard let index = menuIndex(in: redoSteps, redoing: true) else { return }
        let step = redoSteps.remove(at: index)
        guard let done = apply(step, undoing: false) else {
            redoSteps.insert(step, at: index)
            didRefuse(step)
            return
        }
        undoSteps.append(done)
        didStep(done, false)
    }

    /// A card's own Undo — the only way back for a step that raises: the card's latest step for
    /// that row, put back while it is still the latest change, and kept for Redo.
    func undoCard(_ card: UUID, row: Int) {
        guard let index = undoSteps.lastIndex(where: { $0.card == card && $0.rows.contains(row) }) else { return }
        let step = undoSteps[index]
        guard isCurrent(step) else { return }
        undoSteps.remove(at: index)
        guard let done = apply(step, undoing: true) else {
            undoSteps.insert(step, at: index)
            didRefuse(step)
            return
        }
        redoSteps.append(done)
        didStep(done, true)
    }

    /// Whether this card's row made the latest change to its setting: only then does it offer Undo.
    func offersUndo(_ card: UUID, row: Int) -> Bool {
        guard let step = undoSteps.last(where: { $0.card == card && $0.rows.contains(row) }) else { return false }
        return isCurrent(step)
    }

    /// New Chat: the cards are gone, so are their steps. Their changes stay.
    func clear() {
        undoSteps.removeAll()
        redoSteps.removeAll()
    }

    /// Writes the step's values one way, and returns it with the new tokens; nil if a write was refused.
    private func apply(_ step: AskClaudeSettingsStep, undoing: Bool) -> AskClaudeSettingsStep? {
        var done = step
        for (index, change) in step.changes.enumerated() {
            guard write(change.key, undoing ? change.before : change.after) else { return nil }
            // The value an undo puts back carries the token it had, so the step that made it —
            // the one below this on the stack — is the latest change again.
            if undoing, read(change.key) == change.before { ledger.restore(change.key, value: change.before, token: change.beforeToken) }
            done.changes[index].token = token(change.key)
        }
        return done
    }
}
