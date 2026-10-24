import Foundation

/// **The app's words, read from every source file at once** — `MacApp/` and every package's
/// `Sources/` — for the copy rules that hold app-wide: curly apostrophes and quotes and US spelling
/// (TE129, ST16, ST17) and Title Case in menus (TE126, BR9). The rules began as scans of Edit's
/// files and Help; strings everywhere else drifted past them.
///
/// Comments (`//` and `/* */`) are stripped first, string-aware, so a URL in a string survives and
/// a quoted string in a comment does not count. Log statements are skipped — their words are read
/// by us, not by the person using the app — and what is left that is still not the person's to
/// read is named in ``exemptions``, each with its reason.
enum AppCopyScan {

    struct Literal {
        /// Path from the repository root, e.g. `MacApp/HelpBook.swift`.
        let path: String
        let line: Int
        /// The literal as written, quotes and escapes included.
        let text: String
        var fileName: String { (path as NSString).lastPathComponent }
    }

    /// A string the scans must leave alone: in `file` — a path from the repository root, since one
    /// file name can be two files (`FilingClassifier.swift` is in `MacApp` and in Sync) — any
    /// flagged literal that contains `contains`, or every one in the file, where `contains` is
    /// empty. A whole-file exemption hides whatever is written there next, so prefer a fragment.
    struct Exemption {
        let file: String
        let contains: String
        let reason: String

        func covers(_ literal: Literal) -> Bool {
            literal.path == file && (contains.isEmpty || literal.text.contains(contains))
        }
    }

    // MARK: The rules

    /// A straight apostrophe inside a word ("can't"), after a plural ("files' names"), or after an
    /// interpolation ("\(name)'s") — where the character before it is the interpolation's `)`.
    static let straightApostrophe = try! NSRegularExpression(
        pattern: #"[A-Za-z]'[A-Za-z]|[a-z]'(?=[\s.,;:!?)—–"])|\)'[A-Za-z]"#)
    /// An escaped straight double quote — `\"` after an even run of backslashes.
    static let straightQuote = try! NSRegularExpression(pattern: #"(?<!\\)(?:\\\\)*\\""#)
    /// British spellings, as whole words, any case. ("towards" is not one: US English writes it
    /// too.)
    static let britishSpelling = try! NSRegularExpression(pattern: #"\b("#
        + ["colour", "colours", "coloured", "reorganisation", "reorganisations", "reorganise",
           "reorganised", "reorganising", "recognise", "recognises", "recognised", "recognising",
           "judgement", "judgements", "capitalisation", "capitalise", "capitalised", "organise",
           "organised", "organising", "organisation", "labelled", "labelling", "neighbour",
           "neighbours", "synchronise", "synchronised", "centred", "centre", "centres", "grey",
           "greys", "greyed", "greying", "cancelled", "cancelling", "behaviour", "behaviours", "favourite",
           "favourites", "analyse", "analysed", "licence", "catalogue", "dialogue", "travelled",
           "summarise", "summarised", "customise", "customised", "optimise", "optimised",
           "prioritise", "normalise", "normalised", "categorise", "categorised", "initialise",
           "initialised", "authorise", "authorised", "minimise", "minimised", "maximise",
           "maximised", "whilst", "amongst", "organises", "organisations", "realise", "realised",
           "realises", "realising"].joined(separator: "|")
        + #")\b"#, options: .caseInsensitive)

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A straight double quote written bare inside a multi-line literal, where it needs no escape
    /// and so `straightQuote` never sees it. Interpolations are set aside first: their own strings
    /// are code, not copy.
    static func hasBareQuoteInMultiline(_ text: String) -> Bool {
        guard text.hasPrefix("\"\"\""), text.hasSuffix("\"\"\""), text.count >= 6 else { return false }
        let inner = Array(text.dropFirst(3).dropLast(3))
        var i = 0
        while i < inner.count {
            if inner[i] == "\\", i + 1 < inner.count, inner[i + 1] == "(" {
                var depth = 1
                i += 2
                while i < inner.count, depth > 0 {
                    if inner[i] == "(" { depth += 1 } else if inner[i] == ")" { depth -= 1 }
                    i += 1
                }
                continue
            }
            if inner[i] == "\\" { i += 2; continue }
            if inner[i] == "\"" { return true }
            i += 1
        }
        return false
    }

    /// The literals a person reads that break `rule`, outside log statements and outside
    /// `exemptions`. `sentencesOnly` keeps to literals with a space in them — for the quote rule,
    /// where a key or a JSON fragment would drown it. The apostrophe and spelling rules read every
    /// literal: a lone "person's" is a word on screen, and the only space-less straight
    /// apostrophes in the app are date formats (`"yyyy-MM-dd'T'HH"`), exempt by name.
    static func violations(of rule: NSRegularExpression, sentencesOnly: Bool = true,
                           exemptions: [Exemption]) throws -> [Literal] {
        try violations(where: { matches(rule, $0) }, sentencesOnly: sentencesOnly, exemptions: exemptions)
    }

    static func violations(where rule: (String) -> Bool, sentencesOnly: Bool = true,
                           exemptions: [Exemption]) throws -> [Literal] {
        try flagged(by: rule, sentencesOnly: sentencesOnly).filter { literal in
            !exemptions.contains { $0.covers(literal) }
        }
    }

    /// The exemptions in `list` that no longer cover anything `rule` flags — stale, so they would
    /// hide the next string written there.
    static func staleExemptions(_ list: [Exemption], rule: NSRegularExpression,
                                sentencesOnly: Bool = true) throws -> [Exemption] {
        try staleExemptions(list, where: { matches(rule, $0) }, sentencesOnly: sentencesOnly)
    }

    static func staleExemptions(_ list: [Exemption], where rule: (String) -> Bool,
                                sentencesOnly: Bool = true) throws -> [Exemption] {
        let flagged = try flagged(by: rule, sentencesOnly: sentencesOnly)
        return list.filter { exemption in !flagged.contains { exemption.covers($0) } }
    }

    private static func flagged(by rule: (String) -> Bool, sentencesOnly: Bool) throws -> [Literal] {
        try literals().filter { (!sentencesOnly || $0.text.contains(" ")) && rule($0.text) }
    }

    /// Straight apostrophes and quotes that stay: none is shown to anyone.
    static let punctuationExemptions: [Exemption] = {
        let logReason = "a reason that only reaches the log"
        let prompt = "prompt text sent to Claude, never shown in the app"
        let data = "written into a file the app reads back, never shown"
        let dateFormat = "a date format's quoted literal: 'T' is syntax"
        return [
            .init(file: "Modules/Dashboard/Sources/Dashboard/FileActionHandler.swift", contains: "tell application \"Finder\"",
                  reason: "AppleScript source, run and never shown"),
            .init(file: "Modules/FileExplorer/Sources/FileExplorer/RestructureLens.swift", contains: "'T'", reason: dateFormat),
            .init(file: "Modules/FileExplorer/Sources/FileExplorer/RestructurePlanSheet.swift", contains: "'T'", reason: dateFormat),
            .init(file: "Modules/Sync/Sources/Sync/FilingArtifactStamp.swift", contains: "'T'", reason: dateFormat),
            .init(file: "MacApp/ContentView+Editor.swift", contains: "heading menu", reason: logReason),
            .init(file: "MacApp/ContentView+Editor.swift", contains: "in Edit's pane would open it", reason: logReason),
            .init(file: "MacApp/ContentView+Editor.swift", contains: "which is the user's", reason: logReason),
            .init(file: "MacApp/ContentView+Editor.swift", contains: "the pane's selection moved", reason: logReason),
            .init(file: "MacApp/ContentView+PaneTabs.swift", contains: "from a browse tab's menu", reason: logReason),
            .init(file: "MacApp/DuplicateReviewCoordinator.swift", contains: "pane's source", reason: logReason),
            .init(file: "MacApp/DuplicateReviewCoordinator.swift", contains: "a source's root folder", reason: logReason),
            .init(file: "MacApp/EditorHandOffRun.swift", contains: "the header's file name", reason: logReason),
            .init(file: "MacApp/EditorHandOffRun.swift", contains: "a rail row's menu", reason: logReason),
            .init(file: "MacApp/EditorHandOffRun.swift", contains: "the PDF tools' banner", reason: logReason),
            .init(file: "MacApp/EditorLocationDoors.swift", contains: "the source's top", reason: logReason),
            .init(file: "MacApp/EditorLocationDoors.swift", contains: "Compare's left side", reason: logReason),
            .init(file: "MacApp/EditorNewFileFolder.swift", contains: "can't be written to", reason: logReason),
            .init(file: "MacApp/ExternalOpen.swift", contains: "the open file's two versions", reason: logReason),
            .init(file: "MacApp/ExternalOpen.swift", contains: "on Edit's empty page", reason: logReason),
            .init(file: "Modules/Dashboard/Sources/Dashboard/DetailsSidebar.swift", contains: "Details: couldn't read", reason: logReason),
            .init(file: "Modules/FileExplorer/Sources/FileExplorer/MarkupVerbs.swift", contains: "not in a table's body", reason: logReason),
            .init(file: "Modules/FileExplorer/Sources/FileExplorer/PreviewEditorView.swift", contains: "[preview-edit]", reason: logReason),
            .init(file: "Modules/Settings/Sources/Settings/RootsMigration.swift", contains: "iCloud root:", reason: logReason),
            .init(file: "Modules/Sync/Sources/Sync/FileSyncManager+Navigation.swift", contains: "pane's tree", reason: logReason),
            .init(file: "Modules/Sync/Sources/Sync/FileSyncManager+Undo.swift", contains: #" at \(destination.path)"#, reason: logReason),
            .init(file: "Modules/Sync/Sources/Sync/FileSyncManager+Undo.swift", contains: #"\($0.path)"#, reason: logReason),
            .init(file: "Modules/Sync/Sources/Sync/FileSyncManager+Undo.swift", contains: "undo was registered", reason: logReason),
            .init(file: "Modules/Sync/Sources/Sync/FilingProfileStore.swift", contains: "the derived profile's own file names", reason: logReason),
            .init(file: "Modules/Sync/Sources/Sync/FilingProfileStore.swift", contains: "cannot name a directory", reason: logReason),
            .init(file: "Modules/Sync/Sources/Sync/PersonTagStore.swift", contains: "keyed to the document's text", reason: logReason),
            .init(file: "Modules/FileExplorer/Sources/FileExplorer/DisplayCycleTrace.swift", contains: "", reason: "a debug trace for the log"),
            .init(file: "Modules/FileExplorer/Sources/FileExplorer/EditorContentSpotlight.swift", contains: "", reason: "Spotlight query syntax"),
            .init(file: "Modules/FileExplorer/Sources/FileExplorer/SaveAsPDFRender.swift", contains: "function (", reason: "JavaScript run in the hidden web view"),
            .init(file: "Modules/Sync/Sources/Sync/FilingProfileStore.swift", contains: "What each folder IS", reason: data),
            .init(file: "Modules/Sync/Sources/Sync/FilingSurveyStore.swift", contains: "already-filed documents say", reason: data),
            .init(file: "MacApp/FilingClassifier.swift", contains: "the single word 'none'", reason: prompt),
            .init(file: "MacApp/FilingClassifier.swift", contains: "You organize a user's files", reason: prompt),
            // The prompt literals only: the same files hold the model picker's labels, the
            // "Chosen by Claude" reason and the plan sheet's reversal notes, which people read.
            .init(file: "Modules/Sync/Sources/Sync/CloudFilingProtocol.swift", contains: "You organize a user's files", reason: prompt),
            .init(file: "Modules/Sync/Sources/Sync/CloudFilingProtocol.swift", contains: "The user's existing folders", reason: prompt),
            .init(file: "Modules/Sync/Sources/Sync/CloudFilingProtocol.swift", contains: "the file's index from the list", reason: prompt),
            .init(file: "Modules/Sync/Sources/Sync/MappingRefine.swift", contains: "You are helping name folders consistently", reason: prompt),
            .init(file: "Modules/Sync/Sources/Sync/MappingRefine.swift", contains: "the user's current mapping:", reason: prompt),
            .init(file: "Modules/Sync/Sources/Sync/PersonTag.swift", contains: "Keyed by the document's text", reason: data),
            .init(file: "Modules/Sync/Sources/Sync/RestructurePlan.swift", contains: "The family's vouched scheme", reason: data),
            .init(file: "Modules/Sync/Sources/Sync/RestructurePlanner.swift", contains: "target's", reason: data),
        ]
    }()

    /// British spellings that stay.
    static let spellingExemptions: [Exemption] = [
        .init(file: "Modules/Settings/Sources/Settings/SettingsView.swift", contains: #""colour""#,
              reason: "a Settings search synonym: someone typing “colour” still finds Accent color"),
    ]

    // MARK: Title Case in menus

    /// Words Title Case leaves lowercase after the first: articles, conjunctions and the short
    /// prepositions — "Find Duplicates of This", "Copy to…", as the menu bar writes them.
    static let minorWords: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "from", "in",
                                          "into", "nor", "of", "on", "onto", "or", "the", "to", "via", "with", "vs"]

    /// Whether `title` (a literal's body) is in Title Case. Interpolations count as a word that is.
    static func isTitleCase(_ title: String) -> Bool {
        let flat = title.replacingOccurrences(of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: "X", options: .regularExpression)
        let words = flat.split(whereSeparator: { !($0.isLetter || $0 == "’" || $0 == "'" || $0 == "-") })
            .filter { $0.first?.isLetter == true }
        for (index, word) in words.enumerated() {
            if index > 0, minorWords.contains(word.lowercased()) { continue }
            if word.first?.isLowercase == true { return false }
        }
        return true
    }

    /// Menu items whose titles a person reads that are not in Title Case: the titles of `Button`,
    /// `Toggle`, `Label` and `Menu` written inside a `.contextMenu`, a `Menu`, a `CommandMenu` or
    /// `CommandGroup`, a type whose name ends in a menu or command word (the menu bar's content
    /// views — not `CommandPalettePanel…`, which only starts with one) or conforming to `Commands`,
    /// or a function or property named for a menu; inside those, a `Text` in a `label:` closure
    /// (`Button {} label: { Text("…") }`) and a `Text` tagged as a picker's option; and every
    /// `NSMenuItem(title:)` or other `…MenuItem(title:)`. A title is the first argument's literal,
    /// or each branch of a ternary there — not a literal handed to a function that builds one, nor
    /// one held in a constant.
    static func menuTitleViolations(exemptions: [Exemption]) throws -> [Literal] {
        try sourceFiles().flatMap { menuTitleViolations(in: $0.code, path: $0.path) }
            .filter { literal in !exemptions.contains { $0.covers(literal) } }
    }

    /// The same, in one file's code.
    static func menuTitleViolations(in code: String, path: String) -> [Literal] {
        var found: [Literal] = []
        let b = Array(strippedComments(code).utf8)
        let lines = LineIndex(b)
        var seen = Set<Int>()
        for start in menuOpeners(in: b) {
            let span = start.opener..<menuSpanEnd(b, from: start.body)
            for call in itemCalls(in: b, span) + labelTexts(in: b, span) where seen.insert(call).inserted {
                for (offset, text) in firstArgumentTitles(b, from: call) where text.contains(" ") {
                    if !isTitleCase(String(text.dropFirst().dropLast())) {
                        found.append(Literal(path: path, line: lines.line(of: offset), text: text))
                    }
                }
            }
        }
        for (offset, text) in nsMenuItemTitles(in: b) where text.contains(" ") {
            if !isTitleCase(String(text.dropFirst().dropLast())) {
                found.append(Literal(path: path, line: lines.line(of: offset), text: text))
            }
        }
        return found
    }

    static let menuExemptions: [Exemption] = [
        .init(file: "Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSignMenuItems.swift", contains: #") pt""#, reason: "a point size: “12 pt” is a unit"),
        .init(file: "Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillPalette.swift", contains: #") pt""#, reason: "a point size: “12 pt” is a unit"),
    ]

    // MARK: Reading the sources

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FileExplorer
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Modules/FileExplorer
            .deletingLastPathComponent()   // Modules
            .deletingLastPathComponent()   // the repository
    }

    nonisolated(unsafe) private static var cachedFiles: [(path: String, code: String)]?
    nonisolated(unsafe) private static var cachedLiterals: [Literal]?
    private static let lock = NSLock()

    /// Every `.swift` file in `MacApp/` and in each `Modules/<name>/Sources/`, by path.
    static func sourceFiles() throws -> [(path: String, code: String)] {
        lock.lock(); defer { lock.unlock() }
        if let cachedFiles { return cachedFiles }
        let fm = FileManager.default
        var folders = ["MacApp"]
        for module in try fm.contentsOfDirectory(atPath: repoRoot.appendingPathComponent("Modules").path).sorted() {
            let sources = "Modules/\(module)/Sources"
            if fm.fileExists(atPath: repoRoot.appendingPathComponent(sources).path) { folders.append(sources) }
        }
        var files: [(String, String)] = []
        for folder in folders {
            let base = repoRoot.appendingPathComponent(folder)
            guard let walk = fm.enumerator(atPath: base.path) else { continue }
            for case let relative as String in walk where relative.hasSuffix(".swift") {
                let code = try String(contentsOf: base.appendingPathComponent(relative), encoding: .utf8)
                files.append(("\(folder)/\(relative)", code))
            }
        }
        files.sort { $0.0 < $1.0 }
        cachedFiles = files
        return files
    }

    /// Every string literal in the sources outside comments and log statements.
    static func literals() throws -> [Literal] {
        if let cached = (lock.withLock { cachedLiterals }) { return cached }
        var out: [Literal] = []
        for (path, code) in try sourceFiles() {
            out += literals(in: code, path: path)
        }
        lock.withLock { cachedLiterals = out }
        return out
    }

    /// Words on a line that mark it as a log statement; a call they open runs on until its
    /// parentheses close. **Whole tokens only**: as substrings, "log(" matched
    /// `.confirmationDialog(`, `ProgressDialog(` and `.backlog(`, and the titles written there went
    /// unread as if they were log lines.
    static let logMarker = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])(?:Logger\.|logger\.|log\(|logError|logMessage|logLine)"#)

    static func isLogMarked(_ line: String) -> Bool {
        matches(logMarker, line)
    }

    static func literals(in code: String, path: String) -> [Literal] {
        let stripped = strippedComments(code)
        let b = Array(stripped.utf8)
        let lines = LineIndex(b)
        // Which lines are log statements: a marker on the line, or a call it opened still open.
        let oneLine = try! NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        var isLog: [Bool] = [false]   // 1-based
        var depth = 0
        for line in stripped.components(separatedBy: "\n") {
            if depth > 0 || isLogMarked(line) {
                let bare = oneLine.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
                depth = max(depth + bare.filter { $0 == "(" }.count - bare.filter { $0 == ")" }.count, 0)
                isLog.append(true)
            } else {
                isLog.append(false)
            }
        }
        var out: [Literal] = []
        var i = 0
        while i < b.count {
            if b[i] == UInt8(ascii: "\"") {
                let end = stringEnd(b, from: i)
                let line = lines.line(of: i)
                if !(line < isLog.count && isLog[line]) {
                    out.append(Literal(path: path, line: line, text: String(decoding: b[i..<end], as: UTF8.self)))
                }
                i = end
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: A small Swift lexer — enough to skip strings and comments correctly

    private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), newline = UInt8(ascii: "\n")
    private static let openParen = UInt8(ascii: "("), closeParen = UInt8(ascii: ")")

    /// The index just past the string literal that opens at `start` (a `"`), interpolations and
    /// the strings inside them included. A single-line literal left open ends at its newline.
    static func stringEnd(_ b: [UInt8], from start: Int) -> Int {
        let n = b.count
        if start + 2 < n, b[start + 1] == quote, b[start + 2] == quote {
            var j = start + 3
            while j < n {
                if b[j] == backslash { j += 2; continue }
                if j + 2 < n, b[j] == quote, b[j + 1] == quote, b[j + 2] == quote { return j + 3 }
                j += 1
            }
            return n
        }
        var j = start + 1
        while j < n {
            switch b[j] {
            case backslash:
                if j + 1 < n, b[j + 1] == openParen { j = interpolationEnd(b, from: j + 2) } else { j += 2 }
            case quote: return j + 1
            case newline: return j
            default: j += 1
            }
        }
        return n
    }

    private static func interpolationEnd(_ b: [UInt8], from start: Int) -> Int {
        var depth = 1, k = start
        while k < b.count {
            switch b[k] {
            case quote: k = stringEnd(b, from: k); continue
            case openParen: depth += 1
            case closeParen:
                depth -= 1
                if depth == 0 { return k + 1 }
            default: break
            }
            k += 1
        }
        return b.count
    }

    /// `code` with its `//` and `/* */` comments blanked — newlines kept, so line numbers hold.
    static func strippedComments(_ code: String) -> String {
        let b = Array(code.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*")
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == quote {
                let end = stringEnd(b, from: i)
                out += b[i..<end]
                i = end
            } else if c == slash, i + 1 < b.count, b[i + 1] == slash {
                while i < b.count, b[i] != newline { i += 1 }
            } else if c == slash, i + 1 < b.count, b[i + 1] == star {
                i += 2
                while i < b.count, !(b[i] == star && i + 1 < b.count && b[i + 1] == slash) {
                    if b[i] == newline { out.append(newline) }
                    i += 1
                }
                i += 2
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    struct LineIndex {
        private var starts: [Int] = [0]
        init(_ b: [UInt8]) {
            for (i, c) in b.enumerated() where c == UInt8(ascii: "\n") { starts.append(i + 1) }
        }
        /// 1-based.
        func line(of offset: Int) -> Int {
            var lo = 0, hi = starts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo + 1
        }
    }

    private static let menuOpener = try! NSRegularExpression(pattern:
        #"\.contextMenu\s*[({]|\bMenu\s*[({]|\bCommandMenu\s*\(|\bCommandGroup\s*\("#
        + #"|\b(?:struct|enum|extension|class)\s+\w*(?:Menu|Menus|MenuItem|MenuItems|MenuContent|MenuEntry|Command|Commands)\b[^{]*\{"#
        + #"|\bstruct\s+\w+\s*:[^{]*\bCommands\b[^{]*\{"#
        + #"|\bfunc\s+\w*[Mm]enu\w*\b[^{]*\{|\bvar\s+\w*[Mm]enu\w*\s*:[^{=]*\{"#)
    private static let itemCall = try! NSRegularExpression(pattern: #"\b(?:Button|Toggle|Label|Menu)\s*\("#)
    private static let textCall = try! NSRegularExpression(pattern: #"\bText\s*\("#)
    private static let labelClosure = try! NSRegularExpression(pattern: #"\blabel:\s*\{"#)
    private static let nsMenuItem = try! NSRegularExpression(pattern:
        #"\b\w*MenuItem\s*\(\s*title:\s*(?=")|addItem\s*\(\s*withTitle:\s*(?=")"#)

    /// Each opener's start, and where its bracket — the one the match ends on — opens.
    private static func menuOpeners(in b: [UInt8]) -> [(opener: Int, body: Int)] {
        let text = String(decoding: b, as: UTF8.self)
        return menuOpener.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let opener = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
            let end = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound)
            return (opener, end - 1)
        }
    }

    /// The close of the bracket at `start`, and of the trailing closure after it if one follows —
    /// `Menu("Title") { … }` reads through to the content.
    private static func menuSpanEnd(_ b: [UInt8], from start: Int) -> Int {
        var end = closingBracket(b, from: start)
        var k = end + 1
        while k < b.count, b[k] == UInt8(ascii: " ") || b[k] == UInt8(ascii: "\t") || b[k] == newline { k += 1 }
        if k < b.count, b[k] == UInt8(ascii: "{") { end = closingBracket(b, from: k) }
        return min(end + 1, b.count)
    }

    private static func closingBracket(_ b: [UInt8], from start: Int) -> Int {
        var depth = 0, i = start
        while i < b.count {
            let c = b[i]
            if c == quote { i = stringEnd(b, from: i); continue }
            if c == openParen || c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
            if c == closeParen || c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return b.count - 1
    }

    /// Offsets just past each `Button(`, `Toggle(`, `Label(` or `Menu(` that starts in `span`.
    private static func itemCalls(in b: [UInt8], _ span: Range<Int>) -> [Int] {
        calls(of: itemCall, in: b, span)
    }

    /// Offsets just past each `Text(` that titles a menu item without an item call's own title: one
    /// in a `label:` closure, and one tagged as a picker's option (`Text("…").tag(…)`).
    private static func labelTexts(in b: [UInt8], _ span: Range<Int>) -> [Int] {
        var found: [Int] = []
        for open in calls(of: labelClosure, in: b, span) {
            let close = closingBracket(b, from: open - 1)
            found += calls(of: textCall, in: b, open..<min(close + 1, span.upperBound))
        }
        for call in calls(of: textCall, in: b, span) {
            var k = closingBracket(b, from: call - 1) + 1
            while k < b.count, b[k] == UInt8(ascii: " ") || b[k] == newline { k += 1 }
            if b[k...].starts(with: Array(".tag(".utf8)) { found.append(call) }
        }
        return found
    }

    private static func calls(of regex: NSRegularExpression, in b: [UInt8], _ span: Range<Int>) -> [Int] {
        let text = String(decoding: b, as: UTF8.self)
        let utf8 = text.utf8
        let lower = utf8.index(utf8.startIndex, offsetBy: span.lowerBound)
        let upper = utf8.index(utf8.startIndex, offsetBy: span.upperBound)
        return regex.matches(in: text, range: NSRange(lower..<upper, in: text)).compactMap { match in
            Range(match.range, in: text).map { utf8.distance(from: utf8.startIndex, to: $0.upperBound) }
        }
    }

    /// The literals at the top level of the first argument after `start` — one, or a ternary's
    /// two — unless that argument is labelled (`role:`, `action:`, `systemImage:` and the like).
    private static func firstArgumentTitles(_ b: [UInt8], from start: Int) -> [(Int, String)] {
        var i = start
        while i < b.count, b[i] == UInt8(ascii: " ") || b[i] == newline { i += 1 }
        // A labelled first argument is not a title.
        var j = i
        while j < b.count, (b[j] >= UInt8(ascii: "a") && b[j] <= UInt8(ascii: "z")) || (b[j] >= UInt8(ascii: "A") && b[j] <= UInt8(ascii: "Z")) { j += 1 }
        if j > i, j < b.count, b[j] == UInt8(ascii: ":") { return [] }
        var titles: [(Int, String)] = []
        var depth = 0
        while i < b.count {
            let c = b[i]
            if c == quote {
                let end = stringEnd(b, from: i)
                if depth == 0 { titles.append((i, String(decoding: b[i..<end], as: UTF8.self))) }
                i = end
                continue
            }
            if c == openParen || c == UInt8(ascii: "[") || c == UInt8(ascii: "{") { depth += 1 }
            if c == closeParen || c == UInt8(ascii: "]") || c == UInt8(ascii: "}") {
                if depth == 0 { break }
                depth -= 1
            }
            if c == UInt8(ascii: ","), depth == 0 { break }
            i += 1
        }
        return titles
    }

    private static func nsMenuItemTitles(in b: [UInt8]) -> [(Int, String)] {
        let text = String(decoding: b, as: UTF8.self)
        let utf8 = text.utf8
        return nsMenuItem.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let at = utf8.distance(from: utf8.startIndex, to: range.upperBound)
            let end = stringEnd(b, from: at)
            return (at, String(decoding: b[at..<end], as: UTF8.self))
        }
    }
}
