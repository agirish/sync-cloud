import Foundation
import Testing
@testable import FileExplorer

/// **Nothing on the person panel calls anybody *her* or *him*.**
///
/// The panel is drawn for whoever is scoped — seven people on the live roster — and for a while
/// four of its strings said *hers*: the header capsule ("992 hers"), both group titles ("In her
/// folders", "Hers, filed elsewhere") and the misfiling subtitle. Nothing failed, because the
/// fixtures this suite renders are `aditi` and `shweta`; the copy was simply wrong for everyone
/// else, on screen, from the day it shipped. The rest of ``PersonView`` — the gathering line, the
/// empty state — already said *theirs* and *them*, so the file disagreed with itself.
///
/// The guard is a source scan of that one file rather than a render, because the failure is copy
/// written to a fixture and the next instance of it will be a *new* string. A render test can only
/// see the strings someone thought to render.
///
/// Deliberately narrow. A sweep over every module's `Sources` would have to exempt
/// `FilingRouter`'s stop-word list, which holds "he", "she", "his" and "her" as data — and a scan
/// with an exemption list is one entry away from exempting the thing it exists to catch.
@Suite struct PersonCopyTests {

    /// Third person singular, both gendered sets. *Theirs* and *them* are what the file should say
    /// and are not listed.
    private static let gendered = ["her", "hers", "herself", "she", "his", "him", "himself", "he"]

    @Test func testThePersonPanelUsesNoGenderedPronoun() throws {
        let code = Self.codeOnly(try Self.personViewSource())

        // Positive controls FIRST, so an absence assertion cannot pass because the extraction
        // returned nothing, read the wrong file, or stripped away the whole body as comment.
        #expect(code.count > 4_000, "PersonView's code is implausibly short — the scan read nothing")
        #expect(code.contains("groupHeader(symbol:"), "the extracted code draws no group headers")
        #expect(code.contains("private func elsewhereGroup("), "this is not PersonView")

        for word in Self.gendered {
            #expect(!Self.contains(word, in: code), """
                    PersonView says “\(word)”. The panel is drawn for whoever is scoped, so it \
                    names the person (“In \\(displayName)’s folders”) or says they/them/their — \
                    the gathering and empty states already do.
                    """)
        }
    }

    /// The matcher itself fires — otherwise the loop above is a green light for any spelling.
    ///
    /// The four strings this suite was written for, as they stood, plus the one shape a word-
    /// boundary scan is most likely to get wrong in each direction.
    @Test func testTheScanWouldHaveCaughtTheStringsItWasWrittenFor() {
        for old in ["Text(\"\\(files.total) hers\")",
                    "title: \"In her folders\",",
                    "title: \"Hers, filed elsewhere\",",
                    "subtitle: \"Candidate misfilings — named for her, filed somewhere that is not hers.\","] {
            #expect(Self.gendered.contains { Self.contains($0, in: old) },
                    "the scan would not have caught “\(old)”")
        }
        // Bounded on both sides: "other" and "this" are not "her" and "his", and a capitalised
        // pronoun at the start of a title is.
        #expect(!Self.contains("her", in: "let others = otherFolders.count"))
        #expect(!Self.contains("his", in: "// this is the history of it"))
        #expect(Self.contains("hers", in: "\"Hers, filed elsewhere\""))
    }

    /// `word` present as a whole word, either case. Case-insensitive because a title leads with it.
    static func contains(_ word: String, in source: String) -> Bool {
        source.range(of: "\\b\(word)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `source` with `//` comment tails removed — doc comments included.
    ///
    /// Prose about a pronoun is not a use of one, and this file's own header would otherwise fail
    /// it: a guard that cannot survive being documented is not a guard. It also strips the sentence
    /// in ``PersonView``'s type doc that calls the *user* "he", which is accurate and stays.
    static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }

    static func personViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)                 // …/Tests/FileExplorer/<this>
            .deletingLastPathComponent()                          // …/Tests/FileExplorer
            .deletingLastPathComponent()                          // …/Tests
            .deletingLastPathComponent()                          // …/FileExplorer
            .appendingPathComponent("Sources/FileExplorer/PersonView.swift")
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read PersonView.swift — this scan would be vacuous")
    }
}
