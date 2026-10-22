import Testing
import AppKit
import SwiftUI
@testable import FileExplorer

/// **The Contents results, drawn** (RD38) — the rail rendered with the switch on each side, so the
/// results are seen to paint rather than assumed from the model (testing law 1). The renders are
/// left in the temporary folder as `rd38-rail-names.png` and `rd38-rail-contents.png` to look at.
@MainActor
@Suite(.serialized) struct EditorRailContentRenderTests {

    private static let canvas = CGSize(width: EditorLayoutMetrics.railWidth, height: 460)

    /// A model holding a finished search: two text files and a PDF, as the figure on the plan page.
    private func seededModel(scope: EditorRailFilterScope) async -> EditorContentSearchModel {
        let model = EditorContentSearchModel()
        var continuation: AsyncStream<EditorContentSearch.Event>.Continuation?
        model.textSearch = { _, _ in AsyncStream { continuation = $0 } }
        model.spotlightSearch = { _, _, answer in
            answer([EditorContentHit(path: "/Recipes/Guides/Nutrition guide.pdf", name: "Nutrition guide.pdf",
                                     subfolder: "Guides", kind: .pdf)])
        }
        model.scope = .contents
        model.run(.init(folder: "/Recipes", query: "lentils"))
        func line(_ n: Int, _ text: String) -> EditorContentLine {
            let at = (text as NSString).range(of: "lentils")
            return EditorContentLine(line: n, column: at.location + 1, length: 7, snippet: text, highlight: at)
        }
        continuation?.yield(.hit(EditorContentHit(path: "/Recipes/Lentil Soup.md", name: "Lentil Soup.md",
                                                  subfolder: "", kind: .text,
                                                  lines: [line(4, "250 g red lentils")], lineCount: 1), order: 0))
        continuation?.yield(.hit(EditorContentHit(path: "/Recipes/Lists/Shopping.md", name: "Shopping.md",
                                                  subfolder: "Lists", kind: .text,
                                                  lines: [line(12, "- lentils, rice"), line(15, "- red lentils (spare)")],
                                                  lineCount: 3), order: 1))
        var summary = EditorContentSearch.Summary()
        summary.read = 475
        summary.notDownloaded = 2
        continuation?.yield(.finished(summary))
        for _ in 0..<40 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
        model.scope = scope
        return model
    }

    private func rail(_ model: EditorContentSearchModel) -> some View {
        EditorFileRailView(
            folderName: "Recipes",
            entries: [EditorRailEntry(path: "/Recipes/Lentil Soup.md", name: "Lentil Soup.md", size: 61, isCloudOnly: false),
                      EditorRailEntry(path: "/Recipes/Pasta.md", name: "Pasta.md", size: 421, isCloudOnly: false)],
            selectedPath: nil,
            accent: .blue, accentFill: .blue, onAccent: .white,
            tab: .constant(.files),
            isNaming: .constant(false),
            typedName: .constant(""),
            prefilledName: { "Untitled.md" },
            refusal: { _ in nil },
            filter: .constant("lentils"),
            filterIsExpanded: .constant(true),
            outlineAnchors: .constant([:]),
            onOpen: { _ in },
            onCreate: { _ in true },
            onNewTextFile: nil, folderTrail: nil, onGoToFolder: nil,
            rowActions: .inert,
            contentSearch: EditorRailContentSearch(model: model, folder: "/Recipes", onOpen: { _, _ in }))
    }

    private func render<V: View>(_ view: V, named name: String) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(view
            .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .top)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .key)))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rd38-rail-\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return rep
    }

    /// Dark pixels — ink — in a band of rows, in points from the top.
    private func ink(_ rep: NSBitmapImageRep, rows: ClosedRange<Int>) -> Int {
        let scale = rep.pixelsHigh / Int(Self.canvas.height)
        var count = 0
        for y in (rows.lowerBound * scale)...min(rows.upperBound * scale, rep.pixelsHigh - 1) {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.redComponent + c.greenComponent + c.blueComponent < 1.6 { count += 1 }
            }
        }
        return count
    }

    /// **Contents draws its results where Names draws the folder's rows** — and they are not the
    /// same picture: Names lists two files and stops; Contents lists the two files that hold the
    /// word, their lines and the Spotlight group, which reach far further down the rail.
    @Test func theContentsResultsPaint() async {
        let names = render(rail(await seededModel(scope: .names)), named: "names")
        let contents = render(rail(await seededModel(scope: .contents)), named: "contents")
        // The band below the two name rows: empty on Names, the results on Contents.
        let lowNames = ink(names, rows: 190...420)
        let lowContents = ink(contents, rows: 190...420)
        #expect(lowNames < 50, "Names drew \(lowNames) dark pixels below its two rows")
        #expect(lowContents > 400, "Contents drew only \(lowContents) dark pixels where its results go")
    }
}
