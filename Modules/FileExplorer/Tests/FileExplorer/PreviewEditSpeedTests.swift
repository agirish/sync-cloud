import AppKit
import Foundation
import Testing
@testable import FileExplorer

/// How long a keystroke in Preview takes, by note size: a measurement, not a check. It prints and
/// asserts nothing, because CI's timings are its load's. Off unless `TE67_SPEED` is set; run it in
/// Release, on a quiet machine:
///
///     TE67_SPEED=1 swift test -c release --filter PreviewEditSpeedTests
///
/// Last measured p95, against a 4 ms target at 40 KB: the general note about 0.9 / 2.2 / 4.6 /
/// 11.5 ms at 10 / 40 / 100 / 256 KB; one long list about 200 ms at 256 KB, since a list is re-read
/// whole; a note with a reference definition about 47 / 320 ms at 40 / 256 KB, a whole projection
/// per keystroke. The slowest keystroke is printed with its index, since the first can be the slow
/// one. `TE67_SPEED_N` sets the keystrokes per size, for a profiler to sample.
@MainActor
@Suite struct PreviewEditSpeedTests {

    static func note(bytes: Int) -> String {
        let section = """
        ## Section heading

        Some **bold** text, some *italic* text, a [link](https://example.com) and `inline code` in a \
        paragraph that runs on for a while so that it wraps across a few lines in the preview column.

        - First item with **emphasis**
        - Second item with a [link](https://example.com/two)
        - [ ] A task still to do

        | Name | Size |
        | ---- | ---- |
        | one  | 12   |
        | two  | 345  |

        > A quoted line that says something worth quoting.

        ```swift
        let x = 1
        ```


        """
        var text = "# A long note\n\n"
        while text.utf8.count < bytes { text += section }
        return text
    }

    /// A note that is one long list, as a log or a journal kept in bullets is: the list is one
    /// block, so it is re-read whole at every keystroke in it.
    static func list(bytes: Int) -> String {
        var text = "# A long list\n\n"
        var n = 0
        while text.utf8.count < bytes {
            n += 1
            text += "- Item \(n): something noted down, with a **bold** word and a [link](https://example.com)\n"
        }
        return text
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TE67_SPEED"] != nil),
          arguments: [10_000, 40_000, 100_000, 256_000])
    func typingSpeed(bytes: Int) {
        Self.measure(Self.note(bytes: bytes), at: "wraps across", label: "\(bytes / 1000) KB")
    }

    /// The same note with one reference definition at its end, which sends every re-read the whole
    /// way, and the translator re-reads up to three times for one keystroke.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TE67_SPEED"] != nil),
          arguments: [10_000, 40_000, 100_000, 256_000])
    func typingSpeedWithADefinition(bytes: Int) {
        Self.measure(Self.note(bytes: bytes) + "[ref]: https://example.com\n", at: "wraps across",
                     label: "\(bytes / 1000) KB, a definition")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TE67_SPEED"] != nil),
          arguments: [10_000, 40_000, 100_000, 256_000])
    func typingSpeedInOneLongList(bytes: Int) {
        Self.measure(Self.list(bytes: bytes), at: "something noted", label: "\(bytes / 1000) KB, one list")
    }

    static func measure(_ text: String, at word: String, label: String) {
        let source = EditorSourceStorage(text: text)
        let session = PreviewEditSession(source: source, undoManager: UndoManager())
        let rendered = session.projection.rendered.string as NSString
        // `word` near the middle of the note.
        let mid = rendered.range(of: word, options: [], range: NSRange(location: rendered.length / 2,
                                                                       length: rendered.length / 2))
        var at = mid.location
        var samples: [Double] = []
        for i in 0..<(ProcessInfo.processInfo.environment["TE67_SPEED_N"].flatMap(Int.init) ?? 120) {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = session.perform(RenderedEdit(range: NSRange(location: at, length: 0),
                                                      text: i % 7 == 6 ? " " : "x", action: .typing))
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            if case .select(let s) = result { at = s.location } else { at += 1 }
        }
        let projectStart = DispatchTime.now().uptimeNanoseconds
        _ = MarkdownProjection.project(source.textStorage.string, style: session.style)
        let project = Double(DispatchTime.now().uptimeNanoseconds - projectStart) / 1e6
        let slowest = samples.indices.max { samples[$0] < samples[$1] } ?? 0
        samples.sort()
        let p50 = samples[samples.count / 2], p95 = samples[samples.count * 95 / 100]
        print("[speed] \(label): p50 \(String(format: "%.2f", p50)) ms, p95 \(String(format: "%.2f", p95)) ms, max \(String(format: "%.2f", samples.last!)) ms at keystroke \(slowest + 1); one project \(String(format: "%.2f", project)) ms")
    }
}
