import Testing
@testable import Sync

/// TE290 step 7: a message holding an API key is caught before it's sent, and only ever shown or
/// saved masked.
@Suite struct AskClaudeKeyCatchTests {
    private let key = "sk-ant-api03-" + String(repeating: "aB3_-", count: 6)

    @Test func aKeyAnywhereInTheMessageIsCaught() {
        #expect(AskClaudeKeyCatch.key(in: key) == key)
        #expect(AskClaudeKeyCatch.key(in: "here’s my new key \(key), thanks") == key)
        #expect(AskClaudeKeyCatch.key(in: "line one\n\(key)\nline three") == key)
    }

    @Test func aMentionOfThePrefixIsNotAKey() {
        #expect(AskClaudeKeyCatch.key(in: "keys start with sk-ant-, right?") == nil)
        // The design's rule, in numbers: 20 key characters after the prefix make a key, 19 don't.
        #expect(AskClaudeKeyCatch.key(in: "sk-ant-" + String(repeating: "a", count: 19)) == nil)
        #expect(AskClaudeKeyCatch.key(in: "sk-ant-" + String(repeating: "a", count: 20)) != nil)
        #expect(AskClaudeKeyCatch.key(in: "sk-proj-abcdefghijklmnopqrstuvwxyz1234") == nil)
    }

    /// TE290 review: a key a paste broke across lines is still caught, and a key with no kind
    /// keeps nothing of its secret.
    @Test func aBrokenKeyIsCaughtAndABareKeyKeepsNoSecret() {
        #expect(AskClaudeKeyCatch.key(in: "sk-ant-api03-abcdefghij\nklmnopqrstuvwxyz") != nil)
        #expect(AskClaudeKeyCatch.masked("sk-ant-" + String(repeating: "Q", count: 30)) == "sk-ant-••••••••••••")
        #expect(!AskClaudeKeyCatch.masked("my key sk-ant-api03-abcdefghij\nklmnopqrstuvwxyz").contains("abcdef"))
        // A tool's text keeps its lines.
        #expect(AskClaudeKeyCatch.masked("a\nb", joiningLines: false) == "a\nb")
    }

    /// A key in a file a tool read never reaches Claude either.
    @MainActor @Test func aKeyInAToolsResultIsMasked() {
        let call = AskClaudeToolCall(id: "t", name: "read_text", input: .object([:]))
        let sent = AskClaudeEngine.result(for: call, text: "ANTHROPIC_API_KEY=\(key)\nOTHER=1", isError: false)
        guard case .object(let fields) = sent, case .string(let content)? = fields["content"] else { Issue.record("no content"); return }
        #expect(!content.contains("aB3_"))
        #expect(content.contains("OTHER=1"))
    }

    @Test func theMaskedMessageKeepsNoKeyCharactersPastThePrefix() {
        let masked = AskClaudeKeyCatch.masked("here’s my new key \(key) and \(key)")
        #expect(masked == "here’s my new key sk-ant-api03-•••••••••••• and sk-ant-api03-••••••••••••")
        #expect(AskClaudeKeyCatch.key(in: masked) == nil)
        #expect(!masked.contains("aB3_"))
    }
}
