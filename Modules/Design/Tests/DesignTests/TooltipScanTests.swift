import Foundation
import Testing

/// **Every button whose entire label is a glyph must carry a tooltip.**
///
/// A glyph says nothing until the pointer rests on it — the tooltip is the only place a sighted
/// user learns what ✕, ▲ or ⌄ does here. The 2026-10-22 audit found six such buttons with none
/// (two clear-search ✕s, a roster chip's ✕, a diff's ▲▼, a section chevron); this is what stops
/// the seventh.
///
/// A source scan for the same reason as ``UnnamedControlScanTests``: SwiftUI exposes no tooltip
/// to a test process, so a rendered assertion would pass whether `.help` is there or not.
@Suite struct TooltipScanTests {

    /// The chain belonging to the control declared at `start`: lines indented past it, plus lines at
    /// its own indentation that continue it (`.modifier`, `} label: {`, `}`). Comment lines continue
    /// it too, because the codebase explains a modifier directly above it.
    ///
    /// **Stops at the first line indented LESS than the control.** The walker in
    /// `UnnamedControlScanTests` continues through any `}` or `.`-line at or below the control's
    /// indentation, so it can run on into the parent's closing braces and modifiers, where a `.help`
    /// on the parent would hide a button that has none (`aParentsTooltipDoesNotCoverTheButton`).
    /// On the 2026-10-22 tree both walkers found the same six buttons; the planted case is where
    /// they differ.
    static func chain(in lines: [String], from start: Int) -> String {
        let base = lines[start].prefix { $0 == " " }.count
        var end = start + 1
        while end < lines.count {
            let raw = lines[end]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { end += 1; continue }
            let ind = raw.prefix { $0 == " " }.count
            let continues = trimmed.hasPrefix(".") || trimmed.hasPrefix("}")
                || trimmed.hasPrefix(")") || trimmed.hasPrefix("]")
            if ind < base || (ind == base && !continues) { break }
            end += 1
        }
        return lines[start..<end].joined(separator: "\n")
    }

    /// Visible words in the label: `Text(` or `Label(`, but not `accessibilityLabel(` — which names
    /// the control for VoiceOver and shows nothing on screen.
    private static let visibleWords = try! NSRegularExpression(pattern: #"(?<![A-Za-z])(Text|Label)\("#)

    static func isUntippedGlyph(_ block: String) -> Bool {
        guard block.contains("Image(systemName:") else { return false }
        let range = NSRange(block.startIndex..., in: block)
        guard visibleWords.firstMatch(in: block, range: range) == nil else { return false }
        // Hidden from accessibility and from the pointer's attention alike — decoration, not a control.
        guard !block.contains("accessibilityHidden(true)") else { return false }
        return !block.contains(".help(")
    }

    @Test func noGlyphButtonLacksATooltip() throws {
        var found: [String] = []
        for file in try Self.appSwiftSources() {
            // `CloseButton` leaves its tooltip to each caller, checked below.
            guard file.lastPathComponent != "CloseButton.swift" else { continue }
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("Button") || trimmed.hasPrefix("Menu") else { continue }
                if Self.isUntippedGlyph(Self.chain(in: lines, from: i)) {
                    found.append("\(file.lastPathComponent):\(i + 1)")
                }
            }
        }
        #expect(found.isEmpty, "\(found.count) glyph-only control(s) have no tooltip — add `.help`, worded like its `accessibilityLabel`:\n\(found.prefix(12).joined(separator: "\n"))")
    }

    /// Both spellings — `CloseButton(action:)` and the trailing-closure `CloseButton { … }` — and
    /// not a mention in a comment.
    private static let closeButtonCall = try! NSRegularExpression(pattern: #"^\s*CloseButton\s*[({]"#)

    /// `CloseButton` is a bare ✕ whose comment says callers own its words, so the scan above cannot
    /// see it at any call site. Every caller must give it a tooltip.
    @Test func everyCloseButtonHasATooltip() throws {
        var seen = 0
        for file in try Self.appSwiftSources() where file.lastPathComponent != "CloseButton.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where Self.closeButtonCall.firstMatch(
                in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                seen += 1
                #expect(Self.chain(in: lines, from: i).contains(".help("),
                        "\(file.lastPathComponent):\(i + 1) uses CloseButton with no tooltip")
            }
        }
        #expect(seen >= 4, "found only \(seen) CloseButton call sites — the match is stale")
    }

    // MARK: - The scan can fail, and does not overrun

    @Test func theScanFindsAnUntippedGlyph() {
        let planted = """
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
        """.components(separatedBy: "\n")
        #expect(Self.isUntippedGlyph(Self.chain(in: planted, from: 0)),
                "an accessibility label is not a tooltip, and must not read as visible words")
    }

    /// The case the borrowed walker got wrong: the parent's `.help` lies past the button's end.
    @Test func aParentsTooltipDoesNotCoverTheButton() {
        let planted = """
            HStack {
                TextField("Search", text: $query)
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
            .help("Search the help")
        """.components(separatedBy: "\n")
        let block = Self.chain(in: planted, from: 2)
        #expect(!block.contains("Search the help"), "the walker ran on into the parent")
        #expect(Self.isUntippedGlyph(block))
    }

    @Test func aTooltipPastACommentCounts() {
        let tipped = """
                Button(action: step) {
                    Image(systemName: "chevron.down")
                }
                // The key, named the way the capsule names its own.
                .help("Next change")
        """.components(separatedBy: "\n")
        #expect(!Self.isUntippedGlyph(Self.chain(in: tipped, from: 0)))
    }

    @Test func aGlyphWithWordsIsNotOneThisScanOwns() {
        let worded = """
                Button(action: go) {
                    Label("Compare", systemImage: "arrow.left.arrow.right")
                }
        """.components(separatedBy: "\n")
        #expect(!Self.isUntippedGlyph(Self.chain(in: worded, from: 0)))
    }

    /// `MacApp/` plus every module's `Sources/`, with the same vacuity guards as
    /// `UnnamedControlScanTests`.
    private static func appSwiftSources() throws -> [URL] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let modules = repo.appendingPathComponent("Modules")
        var roots = [repo.appendingPathComponent("MacApp")]
        roots += try FileManager.default
            .contentsOfDirectory(at: modules, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("Sources") }
        var files: [URL] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            files += FileManager.default
                .enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
        }
        #expect(files.count > 100, "found only \(files.count) app sources — the roots did not resolve")
        #expect(files.contains { $0.path.hasSuffix("MacApp/SyncCloudApp.swift") }, "MacApp is not being scanned")
        return files
    }
}
