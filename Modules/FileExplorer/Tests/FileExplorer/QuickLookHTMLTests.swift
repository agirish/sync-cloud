import Testing
import Foundation
@testable import FileExplorer

/// **A wedged `qlmanage` is killed and run once more** (`QuickLookHTML.attempts`). A stand-in for the
/// tool wedges as the real one does — idle, for good — on the runs it is told to, and otherwise
/// writes a preview as `qlmanage -p -o <folder> <file>` does. Its wedge is a 600 s `sleep`, which
/// counts time the Mac spends asleep while the guard's clock does not: at 60 s, a 27-minute sleep
/// mid-run (2026-10-21) let the wedge end by itself before the guard fired.
struct QuickLookHTMLTests {
    /// Long enough for the stand-in's good run on a loaded machine; short enough to wait out twice.
    private static let timeout: TimeInterval = 5

    private struct StandIn {
        let tool: URL, folder: URL, runs: URL, pids: URL

        /// `wedges`: the runs (from 1) that wedge. `ignoringTerm`: a wedged run ignores SIGTERM too.
        init(wedges: [Int], ignoringTerm: Bool = false) throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("qlstandin-\(UUID().uuidString)")
            folder = base.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            tool = base.appendingPathComponent("qlmanage")
            runs = base.appendingPathComponent("runs")
            pids = base.appendingPathComponent("pids")
            let script = """
                #!/bin/sh
                echo run >> '\(runs.path)'
                echo $$ >> '\(pids.path)'
                n=$(wc -l < '\(runs.path)' | tr -d ' ')
                case " \(wedges.map(String.init).joined(separator: " ")) " in
                  *" $n "*) mkdir -p "$3/wedged$n.qlpreview"; \(ignoringTerm ? "trap '' TERM; " : "")exec sleep 600 ;;
                esac
                mkdir -p "$3/run$n.qlpreview" && echo '<html></html>' > "$3/run$n.qlpreview/Preview.html"
                """
            try script.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }

        func preview() async -> URL? {
            await QuickLookHTML.preview(of: "/nowhere/Memo.doc", into: folder, tool: tool.path, timeout: timeout)
        }

        var runCount: Int { ((try? String(contentsOf: runs, encoding: .utf8)) ?? "").split(separator: "\n").count }
        /// Stand-in runs still alive — a wedged one the guard failed to end.
        var alive: [Int32] {
            ((try? String(contentsOf: pids, encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { Int32($0) }.filter { kill($0, 0) == 0 }
        }
        func remove() { try? FileManager.default.removeItem(at: tool.deletingLastPathComponent()) }
    }

    @Test func aWedgedRunIsKilledAndRunAgain() async throws {
        let standIn = try StandIn(wedges: [1])
        defer { standIn.remove() }
        let html = await standIn.preview()
        #expect(html?.lastPathComponent == "Preview.html")
        #expect(html?.deletingLastPathComponent().lastPathComponent == "run2.qlpreview")
        #expect(standIn.runCount == 2)
        #expect(standIn.alive.isEmpty)
        // The wedged run's half-made bundle is gone, so it can't be taken for the next run's.
        let left = try FileManager.default.contentsOfDirectory(atPath: standIn.folder.path)
        #expect(left == ["run2.qlpreview"])
    }

    @Test func aWedgedRunThatIgnoresSIGTERMIsKilledAnyway() async throws {
        let standIn = try StandIn(wedges: [1], ignoringTerm: true)
        defer { standIn.remove() }
        let started = ContinuousClock.now
        #expect(await standIn.preview()?.deletingLastPathComponent().lastPathComponent == "run2.qlpreview")
        // About 11 s here: the guard, the 5 s grace, a second run. Unkilled, the wedge would end at
        // 600 s, which is all this bound is for. It was 120 s until GitHub's hosted VMs took 127 s
        // twice (2026-10-29/30) with the guard working; where that time went was not measured.
        #expect(ContinuousClock.now - started < .seconds(300), "the wedged run was left to end on its own")
        #expect(standIn.runCount == 2)
        #expect(standIn.alive.isEmpty)
    }

    @Test func aRunThatWedgesEveryTimeGivesUp() async throws {
        let standIn = try StandIn(wedges: Array(1...QuickLookHTML.attempts + 1))
        defer { standIn.remove() }
        #expect(await standIn.preview() == nil)
        #expect(standIn.runCount == QuickLookHTML.attempts)
        #expect(standIn.alive.isEmpty)
    }

    /// Only a wedge is worth a second run: a file Quick Look can't read stays unread, at once.
    @Test func aRunThatFinishesWithNothingIsNotRunAgain() async throws {
        let standIn = try StandIn(wedges: [])
        defer { standIn.remove() }
        try "#!/bin/sh\necho run >> '\(standIn.runs.path)'\n".write(to: standIn.tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: standIn.tool.path)
        #expect(await standIn.preview() == nil)
        #expect(standIn.runCount == 1)
    }
}
