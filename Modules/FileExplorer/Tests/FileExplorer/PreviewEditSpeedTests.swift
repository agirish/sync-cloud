import AppKit
import Foundation
import Testing
@testable import FileExplorer

/// **How long a keystroke in Preview takes, by note size** (TE67.6) — a measurement, not a check:
/// it prints, and asserts nothing, because CI's timings are its load's. Off unless `TE67_SPEED` is
/// set; run it in Release, on a quiet machine:
///
///     TE67_SPEED=1 swift test -c release --filter PreviewEditSpeedTests
///
/// The 95th percentile, measured: 8 / 35 / 90 / 380 ms at 10 / 40 / 100 / 256 KB on 2026-10-07, when
/// every keystroke re-read and redrew the whole note; 0.77 / 2.40 / 5.84 / 14.07 ms on 2026-10-09,
/// re-reading and redrawing only what changed — under the plan's 4 ms at 40 KB. A note that is one
/// long list: 4.2 / 15.7 / 39.4 / 101.8 ms, the list re-read whole — 340 ms at 256 KB while each
/// re-read also made the list anew and it was redrawn whole. The slowest is printed with its
/// keystroke, because the first one was once the slow one (attributes fixed lazily). On 2026-10-09,
/// the decoration and the display compared only where the projection changed, back to back with
/// the build before on a busy machine (one project ~245 ms at 256 KB, ~1.7× a quiet one): p95
/// 4.53 → 2.57 ms at 40 KB and 26.85 → 14.07 ms at 256 KB; the one long list unchanged, ~190 ms,
/// since it is still re-read whole.
/// A note with one reference definition, which every re-read takes whole: p95 47.99 / 327.15 ms at
/// 40 / 256 KB on 2026-10-10 (one project 43 / 299 ms) — a keystroke is one whole projection. Its
/// lists kept once, for the projection kept rather than each one checked (round 2, R6): 47.19 /
/// 317.65 ms, within the noise, because a letter typed is checked once; the saving is on the
/// keystrokes checked two or three times — an escaped `*`, a verb. The general note, same runs:
/// 2.98 → 2.88 ms at 40 KB, 16.02 → 17.62 ms at 256 KB.
/// The whole TE67 review's fixes against `main` (8d559a26), back to back on 2026-10-12, p95: the
/// general note 1.46 → 0.92 / 4.78 → 2.16 / 10.55 → 4.59 / 27.28 → 11.50 ms at 10 / 40 / 100 /
/// 256 KB; the one long list 194.39 → 197.00 ms at 256 KB — after a check that read the view's
/// storage whole had made it 310 ms (`PreviewListIdentity.wholeLists`).
/// The 50,000-run's fixes (2026-10-12; an empty block after the edit sends the re-read whole), the
/// check off once and on twice, p95: the general note 2.18 → 2.47, 2.16 / 11.55 → 12.97, 11.50 ms
/// at 40 / 256 KB; the one long list 32.11 → 33.03, 34.09 / 205.68 → 206.33, 303.02 ms (one
/// keystroke of 675 ms at load 3.8) — noise: the check is O(1), and a long list never reaches it.
/// `TE67_SPEED_N` sets the keystrokes per size, for a profiler to sample.
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
    /// way — and the translator re-reads up to three times for one keystroke (round 2, R6).
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
