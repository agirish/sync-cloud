import Foundation
import Testing

/// **Decoration stays out of VoiceOver's way, and an empty state's title is a heading.**
///
/// A provider mark always sits beside the source's name, and an empty state's icon is the mood its
/// title already names — read aloud, each is an asset or symbol name ahead of the words that
/// matter. Some logo sites hid the mark and others did not; it is hidden once, in `ProviderLogo`.
///
/// A source scan, for the reason `UnnamedControlScanTests` gives: SwiftUI builds no accessibility
/// tree in a test process with no assistive client attached, so a rendered assertion would pass
/// whether the modifier is there or not.
@Suite struct DecorativeImageScanTests {

    private static func source(_ name: String) throws -> String {
        let design = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Design/\(name)")
        return try String(contentsOf: design, encoding: .utf8)
    }

    /// The line holding `start` and the modifier lines that follow it — one view's chain, ending
    /// at the first line that is not a `.modifier`.
    private static func chain(in text: String, from start: String) throws -> String {
        let lines = text.components(separatedBy: "\n")
        let first = try #require(lines.firstIndex { $0.contains(start) }, "\(start) is gone")
        var out = [lines[first]]
        for line in lines[(first + 1)...] {
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix(".") else { break }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    @Test func theProviderMarkIsHiddenWhereverItIsDrawn() throws {
        let text = try Self.source("ProviderLogo.swift")
        let begin = try #require(text.range(of: "public var body: some View {"))
        let end = try #require(text.range(of: "\n    }", range: begin.upperBound..<text.endIndex))
        let body = text[begin.upperBound..<end.lowerBound]
        #expect(body.contains(".accessibilityHidden(true)"),
                "ProviderLogo's body no longer hides the mark from VoiceOver: \(body)")
    }

    @Test func anEmptyStatesIconIsHiddenAndItsTitleIsAHeading() throws {
        let text = try Self.source("EmptyStateView.swift")
        let icon = try Self.chain(in: text, from: "Image(systemName: icon)")
        let title = try Self.chain(in: text, from: "Text(title)")
        #expect(icon.contains(".accessibilityHidden(true)"), "the empty state's icon is read aloud")
        #expect(title.contains(".accessibilityAddTraits(.isHeader)"),
                "the empty state's title is not a heading")
    }
}
