import Foundation
import Testing
@testable import FileExplorer

/// **No source file in the app calls anybody *her* or *him*.**
///
/// The person panel is drawn for whoever is scoped — seven people on the live roster — and for a
/// while four of its strings said *hers*: the header capsule ("992 hers"), both group titles ("In
/// her folders", "Hers, filed elsewhere") and the misfiling subtitle. Nothing failed, because the
/// fixtures ``PersonViewTests`` renders are `aditi` and `shweta`; the copy was simply wrong for
/// everyone else, on screen, from the day it shipped. The rest of ``PersonView`` — the gathering
/// line, the empty state — already said *theirs* and *them*, so the file disagreed with itself.
///
/// A source scan rather than a render, because the failure is copy written to a fixture and the
/// next instance of it will be a *new* string. A render test can only see the strings someone
/// thought to render.
///
/// ## Why this scans everything, and why that needs no exemption list
///
/// The first cut scanned `PersonView.swift` alone, on the grounds that a wider sweep would have to
/// exempt ``FilingRouter``'s stop-word list — which holds "he", "she", "his" and "her" as *data* —
/// and that a scan carrying an exemption list is one entry away from exempting the thing it exists
/// to catch. That reasoning was sound and the conclusion was still too narrow: a list of surfaces
/// cannot contain the surface nobody has written yet, which is precisely where the next instance
/// lands.
///
/// What resolves it is that the stop words do not need exempting — they need *describing*. A line
/// that is nothing but quoted lowercase words and commas is a word list, and copy is never that
/// shape. So ``isWordListLine(_:)`` allows the shape, not the file: any file may hold a word list,
/// and ``FilingRouter`` gets no special standing. Replace either of those lines with a sentence and
/// this fails, which is what an exemption naming the file could not have promised.
///
/// Measured when written: 312 files scanned, two hits, both of them that word list.
///
/// It lives in FileExplorer's suite for reach rather than for ownership — it scans every module,
/// `MacApp/` and the CLI, and this is the largest UI package in the run that CI's *first* step
/// covers. The app-target step, which the second step runs, is skipped whenever the first is
/// cancelled.
@Suite struct GenderedCopyTests {

    /// Third person singular, both gendered sets. *They*, *them* and *their* are what copy about a
    /// person should say and are not listed.
    static let gendered = ["her", "hers", "herself", "she", "his", "him", "himself", "he"]

    /// The surfaces that draw a person, named so the sweep can be shown to reach them.
    ///
    /// Not the scan's input — the scan takes every file it finds — but its proof of reach. A
    /// discovered set that quietly stopped discovering would otherwise pass by scanning nothing,
    /// and these are the files whose copy the guard was written for.
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

    /// One file per root, for the same reason — and it is a *different* reason from the surfaces
    /// above, which all live under `Modules`. Dropping `MacApp` or the CLI from the walk would
    /// leave every person-surface control green while the sweep quietly stopped covering two of
    /// its three roots.
    private static let oneFilePerRoot = [
        "Modules/Design/Sources/Design/AppChord.swift",
        "MacApp/SyncCloudApp.swift",
        "SyncCloudCLI/Sources/SyncCloudCLI/SyncCloudCommand.swift",
    ]

    @Test func testNoSourceFileUsesAGenderedPronoun() throws {
        let files = try Self.sourceFiles()

        // Positive controls FIRST. An absence assertion over a discovered set is worth exactly what
        // the discovery is worth, and a sweep that found nothing would otherwise report success.
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

        // The word-list allowance is itself pinned: if `isWordListLine` ever stopped matching, the
        // two stop-word lines would land in `offences` and this test would fail for a reason that
        // has nothing to do with copy. Saying the expected number out loud makes that legible.
        #expect(wordLists == 2, "\(wordLists) word-list lines carried a pronoun, expected FilingRouter's 2")
        #expect(offences.isEmpty, """
                \(offences.count) line(s) call somebody her or him:
                \(offences.joined(separator: "\n"))
                Copy about a person is drawn for whoever is scoped, so it names them \
                (“In \\(displayName)’s folders”) or says they/them/their.
                """)
    }

    /// The matcher fires — otherwise the sweep above is a green light for any spelling.
    ///
    /// The four strings this guard was written for, as they stood, plus the shape a word-boundary
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
        // Bounded on both sides: "other" and "this" are not "her" and "his", and a capitalised
        // pronoun leading a title is one.
        #expect(!Self.contains("her", in: "let others = otherFolders.count"))
        #expect(!Self.contains("his", in: "let h = history.first"))
        #expect(Self.contains("hers", in: "\"Hers, filed elsewhere\""))
    }

    /// A line that is nothing but quoted lowercase words and commas — a word list, not a sentence.
    ///
    /// This is what lets the sweep run over everything without naming a file it trusts. Copy never
    /// takes this shape: it has a `Text(`, a `=`, a capital letter, a space inside a quote, or a
    /// word longer than one token. Deliberately strict for that reason.
    static func isWordListLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: "^(?:\"[a-z]+\",[ \t]*)+$", options: .regularExpression) != nil
    }

    /// `word` present as a whole word, either case. Case-insensitive because a title leads with it.
    static func contains(_ word: String, in source: String) -> Bool {
        source.range(of: "\\b\(word)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `line` with any `//` comment tail removed — doc comments included.
    ///
    /// Prose about a pronoun is not a use of one, and this file's own header would otherwise fail
    /// the sweep: a guard that cannot survive being documented is not a guard. It also strips the
    /// sentence in ``PersonView``'s type doc that calls the *user* "he", which is accurate and
    /// stays. The cost is a `//` inside a string literal truncating that line — acceptable, because
    /// this decides only whether a token is ABSENT, and the direction of the error is a missed
    /// occurrence rather than a false alarm on every comment.
    static func codeOnly(_ line: String) -> String {
        guard let comment = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<comment.lowerBound])
    }

    struct SourceFile {
        /// Path from the repo root, which is what a failure has to name to be actionable.
        let relative: String
        let contents: String
    }

    /// Every shipping `.swift` file: each module's `Sources`, the app target, and the CLI.
    ///
    /// Tests are excluded — they say "hers" about the fixture person all over, correctly, and a
    /// fixture named Aditi is not copy. `.build` is excluded because it holds vendored packages.
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
            // `enumerator(at:)` hands back a non-nil enumerator that yields nothing for a directory
            // it cannot list, so there is no `guard let` worth writing here — the count assertion in
            // the test is what proves the walk found anything.
            let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
            while let url = walk?.nextObject() as? URL {
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
