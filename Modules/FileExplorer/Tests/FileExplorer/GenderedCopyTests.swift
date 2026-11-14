import Foundation
import Testing
@testable import FileExplorer

/// No source file in the app calls anybody *her* or *him*. The person panel is drawn for whoever is
/// scoped, so copy like "992 hers" or "In her folders" would be wrong for most people while
/// ``PersonViewTests``, whose fixtures are `daughter` and `mother`, stayed green.
///
/// A source scan rather than a render: the next instance will be a *new* string, which a render
/// test cannot see.
///
/// ## Why this scans everything, with no exemption list
///
/// A list of surfaces cannot contain the one nobody has written yet, so the sweep covers every
/// file. ``FilingRouter``'s stop-word list holds "he", "she", "his" and "her" as *data*, and an
/// exemption list is one entry away from exempting the thing it exists to catch. Instead,
/// ``isWordListLine(_:)`` allows the shape, not the file: a line of nothing but quoted lowercase
/// words and commas is a word list, and copy is never that shape. Replace either stop-word line
/// with a sentence and this fails, which an exemption naming the file could not promise.
///
/// It lives in FileExplorer for reach: it scans every module, `MacApp/` and the CLI, and this is
/// the largest UI package CI's *first* step covers; the app-target step is skipped whenever the
/// first is cancelled.
@Suite struct GenderedCopyTests {

    /// Third person singular, both gendered sets. *They*, *them* and *their* are what copy about a
    /// person should say and are not listed.
    static let gendered = ["her", "hers", "herself", "she", "his", "him", "himself", "he"]

    /// The surfaces that draw a person: not the scan's input but its proof of reach, since a
    /// discovered set that quietly stopped discovering would pass by scanning nothing.
    private static let personSurfaces = [
        "Modules/FileExplorer/Sources/FileExplorer/PersonView.swift",
        "Modules/Settings/Sources/Settings/PersonEditor.swift",
        "Modules/Settings/Sources/Settings/PeopleOverviewRow.swift",
        "Modules/Settings/Sources/Settings/PeopleTester.swift",
        "Modules/Settings/Sources/Settings/SettingsView.swift",
        "Modules/Dashboard/Sources/Dashboard/DashboardViews.swift",
        "Modules/Sync/Sources/Sync/PersonFiles.swift",
        "Modules/Sync/Sources/Sync/PersonFilingFacts.swift",
        "Modules/Sync/Sources/Sync/PeopleStore.swift",
    ]

    /// One file per root, also proof of reach: every surface above lives under `Modules`, so all
    /// could pass with `MacApp` and the CLI unwalked. `Design` stands in for a module with no person
    /// surface.
    private static let oneFilePerRoot = [
        "Modules/Design/Sources/Design/AppChord.swift",
        "MacApp/SyncCloudApp.swift",
        "SyncCloudCLI/Sources/SyncCloudCLI/SyncCloudCommand.swift",
    ]

    @Test func testNoSourceFileUsesAGenderedPronoun() throws {
        let files = try Self.sourceFiles()

        // Positive controls: an absence assertion over a discovered set is worth what the discovery
        // is worth.
        #expect(files.count > 200, "only \(files.count) source files found — the sweep lost its roots")
        for surface in Self.personSurfaces + Self.oneFilePerRoot {
            #expect(files.contains { $0.relative == surface },
                    "\(surface) is not in the scanned set — the guard does not reach the surface it was written for")
        }

        var offences: [String] = []
        var wordLists = 0
        for file in files {
            for (number, line) in file.contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = Self.codeOnly(String(line))
                guard Self.gendered.contains(where: { Self.contains($0, in: code) }) else { continue }
                if Self.isWordListLine(code) { wordLists += 1; continue }
                offences.append("\(file.relative):\(number + 1) — \(code.trimmingCharacters(in: .whitespaces))")
            }
        }

        // The word-list allowance is pinned: if `isWordListLine` stopped matching, the two stop-word
        // lines would fail this for a reason unrelated to copy.
        #expect(wordLists == 2, "\(wordLists) word-list lines carried a pronoun, expected FilingRouter's 2")
        #expect(offences.isEmpty, """
                \(offences.count) line(s) call somebody her or him:
                \(offences.joined(separator: "\n"))
                Copy about a person is drawn for whoever is scoped, so it names them \
                (“In \\(displayName)’s folders”) or says they/them/their.
                """)
    }

    /// The matcher fires, on the four strings this guard is for, and on the shapes a word-boundary
    /// scan is most likely to get wrong in each direction.
    @Test func testTheScanWouldHaveCaughtTheStringsItWasWrittenFor() {
        for old in ["Text(\"\\(files.total) hers\")",
                    "title: \"In her folders\",",
                    "title: \"Hers, filed elsewhere\",",
                    "subtitle: \"Candidate misfilings — named for her, filed somewhere that is not hers.\","] {
            #expect(Self.gendered.contains { Self.contains($0, in: old) },
                    "the scan would not have caught “\(old)”")
            // And the allowance must not swallow one: a sentence is not a word list.
            #expect(!Self.isWordListLine(old), "“\(old)” was mistaken for a word list")
        }
        // A `//` inside a string is not a comment: truncating at the scheme would let the copy through.
        #expect(Self.contains("her", in: Self.codeOnly(#"foo(url: "https://x", label: "In her folders")"#)),
                "copy after a URL was stripped as a comment — the sweep cannot see it")
        // While a real comment still goes, including the one that documents this rule.
        #expect(!Self.contains("her", in: Self.codeOnly("let n = 1   // named for her")))
        #expect(!Self.contains("her", in: Self.codeOnly("/// **In her folders** used to be the heading")))
        // An escaped quote does not end the string, so the `//` after it is still content.
        #expect(Self.contains("her", in: Self.codeOnly(##"say("a \"b\" c // her")"##)))
        // Bounded on both sides: "other" and "this" are not "her" and "his", and a capitalised
        // pronoun leading a title is one.
        #expect(!Self.contains("her", in: "let others = otherFolders.count"))
        #expect(!Self.contains("his", in: "let h = history.first"))
        #expect(Self.contains("hers", in: "\"Hers, filed elsewhere\""))
    }

    /// A line that is nothing but quoted lowercase words and commas: a word list, not a sentence.
    /// Deliberately strict: copy always has a `Text(`, a `=`, a capital letter, a space inside a
    /// quote, or a word longer than one token.
    static func isWordListLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: "^(?:\"[a-z]+\",[ \t]*)+$", options: .regularExpression) != nil
    }

    /// `word` present as a whole word, either case. Case-insensitive because a title leads with it.
    static func contains(_ word: String, in source: String) -> Bool {
        source.range(of: "\\b\(word)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `line` with its `//` comment tail removed, doc comments included: prose about a pronoun is
    /// not a use of one (``PersonView``'s type doc calls the *user* "he", accurately).
    ///
    /// A `//` inside a string literal is not a comment, or `foo(url: "https://x", label: "In her
    /// folders")` would truncate at the scheme and the copy after it would never be scanned. So
    /// quotes are tracked, with `\\` escapes respected.
    ///
    /// A line inside a `"""` block with an odd number of quotes leaves the tracker mid-string, so a
    /// `//` on it is kept rather than cut: the safe direction, since the line is scanned in full.
    static func codeOnly(_ line: String) -> String {
        var inString = false
        var escaped = false
        var kept = ""
        var previousWasSlash = false
        for character in line {
            if escaped {
                escaped = false
                kept.append(character)
                previousWasSlash = false
                continue
            }
            switch character {
            case "\\" where inString:
                escaped = true
                previousWasSlash = false
            case "\"":
                inString.toggle()
                previousWasSlash = false
            case "/" where !inString:
                if previousWasSlash { kept.removeLast(); return kept }   // drop the first slash too
                previousWasSlash = true
            default:
                previousWasSlash = false
            }
            kept.append(character)
        }
        return kept
    }

    struct SourceFile {
        /// Path from the repo root, which is what a failure has to name to be actionable.
        let relative: String
        let contents: String
    }

    /// Every shipping `.swift` file: each module's `Sources`, the app target, and the CLI. Tests are
    /// excluded (they say "hers" about the fixture person, correctly), and so is `.build` (vendored).
    static func sourceFiles() throws -> [SourceFile] {
        let root = URL(fileURLWithPath: #filePath)                // …/Tests/FileExplorer/<this>
            .deletingLastPathComponent()                          // …/Tests/FileExplorer
            .deletingLastPathComponent()                          // …/Tests
            .deletingLastPathComponent()                          // …/FileExplorer
            .deletingLastPathComponent()                          // …/Modules
            .deletingLastPathComponent()                          // the repo root
        var found: [SourceFile] = []
        for top in ["Modules", "MacApp", "SyncCloudCLI"] {
            let dir = root.appendingPathComponent(top)
            // `enumerator(at:)` returns a non-nil enumerator that yields nothing for a directory it
            // cannot list; the count assertion in the test proves the walk found anything.
            let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
            while let url = walk?.nextObject() as? URL {
                // Skipped whole: `Modules/*/.build` holds tens of thousands of vendored files, slow to
                // walk and possibly being written by another session's build.
                if url.lastPathComponent == ".build" || url.lastPathComponent == "Tests" {
                    walk?.skipDescendants()
                    continue
                }
                guard url.pathExtension == "swift" else { continue }
                let path = url.path
                guard !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
                // Inside Modules only the shipping half counts; Package.swift and plugins do not.
                guard top != "Modules" || path.contains("/Sources/") else { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                found.append(SourceFile(relative: String(path.dropFirst(root.path.count + 1)),
                                        contents: text))
            }
        }
        return try #require(found.isEmpty ? nil : found, "no source files found — this scan would be vacuous")
    }
}
