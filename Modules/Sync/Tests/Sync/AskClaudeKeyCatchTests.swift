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

    @Test func theMaskedMessageKeepsNoKeyCharactersPastThePrefix() {
        let masked = AskClaudeKeyCatch.masked("here’s my new key \(key) and \(key)")
        #expect(masked == "here’s my new key sk-ant-api03-•••••••••••• and sk-ant-api03-••••••••••••")
        #expect(AskClaudeKeyCatch.key(in: masked) == nil)
        #expect(!masked.contains("aB3_"))
    }
}
