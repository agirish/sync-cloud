import AppKit
import Testing
@testable import Design

/// **Every button whose entire label is a glyph must carry an `accessibilityLabel`.**
///
/// On macOS `.help()` is the accessibility *help*, not the name, so a control whose label is one
/// `Image(systemName:)` and nothing else is announced with no name at all — VoiceOver reads
/// "button", and Voice Control cannot be told to click it by name, only by number. Twenty-six such
/// controls were named in one pass; this is what stops the twenty-seventh appearing.
///
/// **Why a source scan and not a rendered assertion.** SwiftUI builds no accessibility tree in a
/// test process without an assistive client attached, so a test that renders one of these buttons
/// and asks for its label gets nothing back whether the label is present or absent — it would pass
/// vacuously in exactly the state it exists to catch. The source is the only place the answer is
/// legible here.
@Suite struct UnnamedControlScanTests {

    /// A `Button`/`Menu` whose modifier chain contains a system image, no text of any kind, and no
    /// accessibility label.
    private struct Unnamed {
        let file: String
        let line: Int
    }

    /// The chain belonging to the control declared at `start`.
    ///
    /// Extent is decided by indentation rather than a fixed number of lines, and **comment lines
    /// continue the chain**. Both matter: a fixed window found phantom hits because a label sat one
    /// line past the window, and the codebase habitually explains a modifier directly above it, so
    /// stopping at a comment cut chains in half. The first version of this scan reported 43 sites;
    /// with both fixed, 26 — and every one of the 17 differences was a control that was already
    /// named.
    private static func chain(in lines: [String], from start: Int) -> String {
        let base = lines[start].prefix { $0 == " " }.count
        var end = start + 1
        while end < lines.count {
            let raw = lines[end]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { end += 1; continue }
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { end += 1; continue }
            let ind = raw.prefix { $0 == " " }.count
            let continues = trimmed.hasPrefix(".") || trimmed.hasPrefix("}")
                || trimmed.hasPrefix(")") || trimmed.hasPrefix("]")
            if ind <= base && !continues { break }
            end += 1
        }
        return lines[start..<end].joined(separator: "\n")
    }

    private static func unnamedControls(in files: [URL]) throws -> [Unnamed] {
        var found: [Unnamed] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("Button") || trimmed.hasPrefix("Menu") else { continue }
                let block = chain(in: lines, from: i)
                guard block.contains("Image(systemName:") else { continue }
                // Any text in the label names the control already — that is what `Label(_:systemImage:)` is.
                guard !block.contains("Text(") && !block.contains("Label(") else { continue }
                guard !block.contains("accessibilityLabel") else { continue }
                // A control hidden from accessibility is not an unnamed one; it is not there at all.
                guard !block.contains("accessibilityHidden(true)") else { continue }
                found.append(Unnamed(file: file.lastPathComponent, line: i + 1))
            }
        }
        return found
    }

    @Test func noButtonIsAGlyphWithNoName() throws {
        let files = try Self.appSwiftSources()
        let unnamed = try Self.unnamedControls(in: files)
        let report = unnamed.prefix(12).map { "\($0.file):\($0.line)" }.joined(separator: "\n")
        #expect(unnamed.isEmpty,
                "\(unnamed.count) glyph-only control(s) announce no name. `.help` is the accessibility HELP on macOS, not the name — add `.accessibilityLabel`, using the control's own help text where it has one so the spoken name and the tooltip agree:\n\(report)")
    }

    /// **The scan has to be able to fail.** A chain-walker that silently stopped matching would make
    /// the test above pass on any tree at all — the failure mode a source scan dies of.
    @Test func theScanFindsAnUnnamedControl() {
        let planted = """
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help("Delete this thing")
        """.components(separatedBy: "\n")
        let block = Self.chain(in: planted, from: 0)
        #expect(block.contains("Image(systemName:"), "the walker no longer reaches the label")
        #expect(block.contains(".help("), "the walker stops before the modifier chain")
        #expect(!block.contains("accessibilityLabel"), "the planted control is supposed to be unnamed")
    }

    /// And the other direction: a named control must NOT be reported, including when the label sits
    /// below a comment. That pairing is what the 43-vs-26 discrepancy was.
    @Test func theScanAcceptsANamedControlPastAComment() {
        let named = """
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                // The name has to survive somewhere reachable, so it is spelled out here.
                .accessibilityLabel("Delete this thing")
        """.components(separatedBy: "\n")
        let block = Self.chain(in: named, from: 0)
        #expect(block.contains("accessibilityLabel"),
                "a comment cut the chain — every control explained above its label would be a phantom hit")
    }

    /// Same roots and same vacuity guards as `GeometryScaleTests` — `MacApp/` is a sibling of
    /// `Modules/` and in no SPM package, so it has to be added by hand or the scan silently skips
    /// the app's own views.
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
        #expect(!files.contains { $0.path.contains("/.build/") }, "a dependency source leaked in")
        return files
    }
}
