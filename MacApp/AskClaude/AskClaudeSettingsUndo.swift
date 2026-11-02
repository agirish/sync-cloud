import Foundation
import Settings
import Sync

/// Which change a setting's value came from (TE290 step 4b): a new token every time the value
/// moves, whoever moved it — a card, Settings, the View menu, the toolbar, the shield, a reset.
///
/// **Watched, not told.** Only a card's writes come through the chat; everything else writes the
/// preferences or a store directly. So the ledger compares the live values each time it is asked,
/// and a value that differs from the last one it saw gets a fresh token. A card that holds the
/// current token made the latest change; one that doesn't, didn't — and its Undo would overwrite
/// something newer, so it offers none. Tokens last for the session: a card restored after a relaunch
/// holds none, and offers no Undo.
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
}

/// One change a card made, undoable: the setting, what it was and what it became, and the token
/// of that change. Apply All's several rows are one step.
struct AskClaudeSettingsStep {
    struct Change {
        let key: AskClaudeSettingsLedger.Key
        let before: SettingValue
        let after: SettingValue
        var token: UUID
    }

    let card: UUID
    let rows: [Int]
    var changes: [Change]
    /// "Theme", or the card's title for several.
    let name: String
    /// Undoing it would raise Claude's spending or access, so only the card's own Undo — badged —
    /// takes it back; ⌘Z passes over it and can't quietly turn reading back on.
    let cardOnly: Bool
}

/// The chat's own undo and redo of settings changes (TE290 step 4b), separate from typing's.
///
/// **Separate, so it survives the panel.** The panel's window — and its undo manager — is torn
/// down whenever the panel closes or steps aside for Settings; steps kept there went with it. The
/// chat owns these for as long as it lives; New Chat clears them with the cards they belong to.
/// The panel window sends Undo here when there is no draft being typed (`AskClaudePanelWindow`).
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

    /// Records a change a card just made.
    func record(_ step: AskClaudeSettingsStep) {
        undoSteps.append(step)
        redoSteps.removeAll()
    }

    /// The changes Claude made itself (TE290 step 4c), once their card is in the chat as `card`:
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

    /// Whether `step` still describes the live values: nothing changed any of them since.
    func isCurrent(_ step: AskClaudeSettingsStep) -> Bool {
        step.changes.allSatisfy { token($0.key) == $0.token }
    }

    /// The newest step ⌘Z may take: still current (an undo never overwrites something newer), and
    /// not one only its card's Undo takes back.
    private func menuIndex(in steps: [AskClaudeSettingsStep]) -> Int? {
        steps.indices.reversed().first { !steps[$0].cardOnly && isCurrent(steps[$0]) }
    }

    var canUndo: Bool { menuIndex(in: undoSteps) != nil }
    var canRedo: Bool { menuIndex(in: redoSteps) != nil }
    var undoTitle: String? { menuIndex(in: undoSteps).map { "Undo \(undoSteps[$0].name)" } }
    var redoTitle: String? { menuIndex(in: redoSteps).map { "Redo \(redoSteps[$0].name)" } }

    /// Edit ▸ Undo and ⌘Z.
    func undo() {
        guard let index = menuIndex(in: undoSteps) else { return }
        let step = undoSteps.remove(at: index)
        guard let done = apply(step, undoing: true) else { return }
        redoSteps.append(done)
        didStep(done, true)
    }

    /// Edit ▸ Redo and ⇧⌘Z.
    func redo() {
        guard let index = menuIndex(in: redoSteps) else { return }
        let step = redoSteps.remove(at: index)
        guard let done = apply(step, undoing: false) else { return }
        undoSteps.append(done)
        didStep(done, false)
    }

    /// A card's own Undo — the only way back for a step that raises: the card's latest step for
    /// that row, put back while it is still the latest change, and kept for Redo.
    func undoCard(_ card: UUID, row: Int) {
        guard let index = undoSteps.lastIndex(where: { $0.card == card && $0.rows.contains(row) }) else { return }
        let step = undoSteps.remove(at: index)
        guard isCurrent(step), let done = apply(step, undoing: true) else { return }
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
            done.changes[index].token = token(change.key)
        }
        return done
    }
}
