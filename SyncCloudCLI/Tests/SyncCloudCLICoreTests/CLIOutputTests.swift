import Foundation
import Testing
@testable import SyncCloudCLICore

/// **The tool prints plain ASCII punctuation** (FC10). `CommandRunnerTests` pins the fold on a
/// real run's curly reason; these pin the fold itself and the error ArgumentParser prints.
@Suite struct CLIOutputTests {

    @Test func foldsCurlyQuotesTheEllipsisAndDashes() {
        #expect(CLIOutput.ascii("Dropbox doesn’t allow ‘this’ — or “that” – wait…")
                == "Dropbox doesn't allow 'this' - or \"that\" - wait...")
        // Everything else passes through, the arrow the plan draws included.
        #expect(CLIOutput.ascii("- b.txt → [missing-on-right] café") == "- b.txt → [missing-on-right] café")
    }

    /// **A name marked verbatim is printed as it is; the words around it fold; no marker is
    /// printed** (FC10) — including when there is nothing to fold, the case a fast path skipped.
    @Test func aVerbatimNameIsLeftAloneAndItsMarkersStripped() {
        let line = "Skipping \(CLIOutput.verbatim("Bob’s “Report – Final”.pdf")): it couldn’t — wait…"
        #expect(CLIOutput.ascii(line) == "Skipping Bob’s “Report – Final”.pdf: it couldn't - wait...")
        #expect(CLIOutput.ascii("in \(CLIOutput.verbatim("plain.txt"))") == "in plain.txt")
        #expect(CLIOutput.stripped(line) == "Skipping Bob’s “Report – Final”.pdf: it couldn’t — wait…")
        // Two names in one line, and a name nested inside a marked span, each end where they should.
        #expect(CLIOutput.ascii("\(CLIOutput.verbatim("a’"))’\(CLIOutput.verbatim("b’"))") == "a’'b’")
        #expect(CLIOutput.ascii(CLIOutput.verbatim("x’ \(CLIOutput.verbatim("y’")) z’") + "’") == "x’ y’ z’'")
        // A name that begins with a combining mark: read by scalar, the marker cannot fuse into it.
        #expect(CLIOutput.ascii(CLIOutput.verbatim("\u{301}é’")) == "\u{301}é’")
    }

    /// **An unbalanced marker folds nothing after it and is still stripped**; a stray end marker
    /// is dropped and folding carries on. Neither crashes or prints a marker.
    @Test func anUnbalancedMarkerFoldsNothingAfterItAndIsStripped() {
        #expect(CLIOutput.ascii("it’s \u{E000}Bob’s — rest…") == "it's Bob’s — rest…")
        #expect(CLIOutput.ascii("it’s \u{E001}Bob’s — rest…") == "it's Bob's - rest...")
        #expect(CLIOutput.ascii("\u{E000}") == "")
        #expect(CLIOutput.ascii("\u{E001}\u{E001}’") == "'")
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
