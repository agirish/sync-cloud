import Foundation
import Testing
@testable import SyncCloudCLICore

/// **The tool prints plain ASCII punctuation** (FC10). `CommandRunnerTests` pins it on real runs,
/// names and all; these pin the fold itself and the error ArgumentParser prints.
@Suite struct CLIOutputTests {

    @Test func foldsCurlyQuotesTheEllipsisAndDashes() {
        #expect(CLIOutput.ascii("Dropbox doesn’t allow ‘this’ — or “that” – wait…")
                == "Dropbox doesn't allow 'this' - or \"that\" - wait...")
        // Everything else passes through, the arrow and the dot the tool draws included, and a
        // private-use character a name may carry.
        #expect(CLIOutput.ascii("- b.txt → [missing-on-right] café · \u{E000}x\u{E001}")
                == "- b.txt → [missing-on-right] café · \u{E000}x\u{E001}")
        #expect(CLIOutput.ascii("") == "")
    }

    /// **A name the sentence quotes is kept; only the words around it fold** (RE2): both
    /// spellings of a name conflict, each wherever it occurs, and a name that is a prefix of
    /// another. A name with nothing to fold, or empty, changes nothing.
    @Test func aKeptNameIsLeftAsItIsAndTheWordsAroundItFold() {
        let sentence = "Names differ by a trailing space: “Bob’s ” (Mom’s Files) vs “Bob’s” (Dropbox) — Bob’s"
        #expect(CLIOutput.ascii(sentence, keeping: ["Bob’s ", "Bob’s", "Mom’s Files", "Dropbox", ""])
                == "Names differ by a trailing space: \"Bob’s \" (Mom’s Files) vs \"Bob’s\" (Dropbox) - Bob’s")
        // The control: the same sentence with no names kept folds them all.
        #expect(CLIOutput.ascii(sentence)
                == "Names differ by a trailing space: \"Bob's \" (Mom's Files) vs \"Bob's\" (Dropbox) - Bob's")
        // Matched by scalar: a decomposed spelling of a kept name is a different name.
        #expect(CLIOutput.ascii("“Cafe\u{301}’”", keeping: ["Café’"]) == "\"Cafe\u{301}'\"")
    }

    /// A message ArgumentParser prints as `Error: …` is read the way it reads one, then folded.
    @Test func anErrorArgumentParserPrintsCarriesTheFoldedMessage() throws {
        struct Curly: LocalizedError { var errorDescription: String? { "The file “a.txt” couldn’t be opened." } }
        let folded = try #require(CLIOutput.foldedForPrinting(Curly()) as? CLIOutput.FoldedError)
        #expect(folded.errorDescription == "The file \"a.txt\" couldn't be opened.")

        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                            userInfo: [NSLocalizedDescriptionKey: "You don’t have permission."])
        let foldedCocoa = try #require(CLIOutput.foldedForPrinting(cocoa) as? CLIOutput.FoldedError)
        #expect(foldedCocoa.errorDescription == "You don't have permission.")

        // With the file's name kept, and passed on as itself the second time round.
        struct Named: LocalizedError { var errorDescription: String? { "The file “Bob’s.txt” couldn’t be opened." } }
        let kept = try #require(CLIOutput.foldedForPrinting(Named(), keeping: ["Bob’s.txt"]) as? CLIOutput.FoldedError)
        #expect(kept.errorDescription == "The file \"Bob’s.txt\" couldn't be opened.")
        #expect(CLIOutput.foldedForPrinting(kept) as? CLIOutput.FoldedError == kept)
    }

    /// The control: an error with nothing to fold is passed on as itself, so ArgumentParser's own
    /// types and every exit code they carry are untouched.
    @Test func anErrorWithNothingToFoldIsItself() {
        struct Plain: LocalizedError, Equatable { var errorDescription: String? { "plain words" } }
        #expect(CLIOutput.foldedForPrinting(Plain()) as? Plain == Plain())
        struct Bare: Error, Equatable {}
        #expect(CLIOutput.foldedForPrinting(Bare()) as? Bare == Bare())
    }
}
