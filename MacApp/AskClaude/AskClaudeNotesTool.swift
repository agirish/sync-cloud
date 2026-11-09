import Foundation
import Sync

/// The `notes` tool (TE307): Claude's changes to its notes about them. Every guard is
/// `AskClaudeNotes.apply`'s; this reads the call and words the result.
extension AskClaudeBrowseTools {

    func notes(_ call: AskClaudeToolCall, _ ctx: Context) -> AskClaudeToolOutcome {
        // Only while the chat is on screen, so the ✎ line and its Undo are in front of them.
        guard ctx.chatIsOpen, ctx.busyReason == nil else {
            return AskClaudeToolOutcome(result: "Not saved: the chat isn’t on screen, so they wouldn’t see the note or its Undo.",
                                        isError: true, step: "Didn’t note it: the chat isn’t on screen")
        }
        let action = (call.string("action") ?? "").lowercased()
        let edit: AskClaudeNotes.Edit
        switch action {
        case "add":
            guard let section = AskClaudeNotes.Section(rawValue: (call.string("section") ?? "").lowercased()) else {
                return refused("Not saved: section is about, layout or answers.")
            }
            edit = .add(text: call.string("text") ?? "", section: section, because: call.string("because") ?? "")
        case "replace":
            guard let line = call.int("line"), let old = call.string("old") else {
                return refused("Not changed: replace needs line and old, from the newest <notes>.")
            }
            edit = .replace(line: line, old: old, text: call.string("text") ?? "", because: call.string("because") ?? "")
        case "remove":
            guard let line = call.int("line"), let old = call.string("old") else {
                return refused("Not changed: remove needs line and old, from the newest <notes>.")
            }
            edit = .remove(line: line, old: old)
        default:
            return refused("action is add, replace or remove.")
        }
        let store = ctx.notesStore()
        switch store.apply(edit, ownWords: ctx.ownWords, onlyWhenAsked: ctx.notesOnlyWhenAsked) {
        case .success(let noted):
            let size = store.read().count
            let full = size >= AskClaudeNotes.nearlyFull ? " Nearly full: merge lines before you add more." : ""
            return AskClaudeToolOutcome(result: "Saved: \(size) of \(AskClaudeNotes.limit) characters.\(full)",
                                        step: noted.line, logStep: "Noted (\(noted.change.rawValue))", noted: noted)
        case .failure(let refusal):
            return refused(refusal.reason)
        }
    }

    private func refused(_ why: String) -> AskClaudeToolOutcome {
        AskClaudeToolOutcome(result: why, isError: true, step: "Didn’t note it", logStep: "Didn’t note it: \(why.prefix(60))")
    }
}
