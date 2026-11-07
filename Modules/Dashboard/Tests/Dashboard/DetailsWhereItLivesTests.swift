import Testing
import AppKit
import SwiftUI
import Sync
@testable import Dashboard

/// The Info inspector's *Where it lives* rows: the supporting "On this Mac" fact and the verdict
/// beneath it.
///
/// Two layers, because they fail differently. The wording is a pure function, pinned exhaustively,
/// including states a real filesystem can't produce. What the card lays out is pinned by mounting
/// it over real files, so the plumbing from stat to state to row has to work.
/// `.serialized` because the layout cases order a real window in (off every display, but really
/// rendering) so SwiftUI commits their async-loaded state; see `mount`. Two suites rendering
/// windows at once repaint each other, which no settling can wait out.
@MainActor
@Suite(.serialized) struct DetailsWhereItLivesTests {

    // MARK: The supporting fact — every state, including the unproducible ones

    /// A file's row, by what the stat answered (`isCloudOnly`, `hasAnswer`):
    /// - downloaded says so;
    /// - a dataless placeholder says so, as a fact about the content, not a warning;
    /// - until the `lstat` lands the row is a placeholder, not an answer. The stat runs off the
    ///   main actor because it can block for seconds on a wedged provider, and a guessed "Yes —
    ///   downloaded" would be wrong exactly when the answer mattered;
    /// - a stat that couldn't answer draws no row. `isCloudOnlyIfKnown` is nil when the path can't
    ///   be statted (deleted mid-download, or never there), and "Unknown" would suggest SyncCloud
    ///   looked and found nothing. Unlike the case before, `hasAnswer` is true: the stat ran and
    ///   came back empty.
    @Test(arguments: [
        (false, true, "Yes — downloaded"),
        (true, true, "No — placeholder only"),
        (nil, false, "Checking…"),
        (nil, true, nil),
    ] as [(Bool?, Bool, String?)])
    func aFilesOnThisMacRowSaysWhatTheStatAnswered(isCloudOnly: Bool?, hasAnswer: Bool, expected: String?) {
        #expect(DetailsSidebar.onThisMacText(isDirectory: false, isCloudOnly: isCloudOnly,
                                             hasAnswer: hasAnswer) == expected)
    }

    /// A folder has no content of its own to be downloaded (its children each answer differently),
    /// so it never gets the row. Asserted across every materialization state, so the rule can't hold
    /// by accident.
    @Test func aFolderIsNeverToldItsContentIsOrIsNotHere() {
        for answer: Bool? in [true, false, nil] {
            for hasAnswer in [true, false] {
                #expect(DetailsSidebar.onThisMacText(isDirectory: true, isCloudOnly: answer,
                                                     hasAnswer: hasAnswer) == nil,
                        "a folder was given an On this Mac row")
            }
        }
    }

    // MARK: What the card lays out

    /// Tall on purpose. The inspector is a `ScrollView`, so nothing past the frame's bottom is
    /// painted, and the *Where it lives* rows sit below the Path row, which wraps over several
    /// lines at this width. A shorter canvas would cut them off and every comparison would read
    /// zero difference.
    private static let canvas = CGSize(width: 320, height: 1400)

    private func fixture(_ prefix: String) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// One mounted inspector, kept alive with the window it paints into.
    ///
    /// The coverage is swapped on this one host rather than compared across two. Two mounts load
    /// on their own clocks, so comparing them measures how far each got as much as the rows, and
    /// can both pass with the rows deleted and differ when they should match. One host loaded once,
    /// with only `cloudCoverage` changing, leaves the rows as the only possible delta. Assigning
    /// `rootView` keeps the structural identity, so `@State` and the landed answers survive.
    private final class Inspector {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let path: String
        init(host: NSHostingView<AnyView>, window: NSWindow, path: String) {
            self.host = host
            self.window = window
            self.path = path
        }
    }

    private func body(path: String, coverage: FileLocation.Coverage?) -> AnyView {
        AnyView(DetailsSidebar(syncManager: FileSyncManager(), leftPath: "", rightPath: "",
                               overridePath: path, singleSource: false,
                               cloudCoverage: coverage)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
    }

    /// Everything the card must stay clear of: the union of every attached display. Never empty:
    /// with no displays, "intersects no screen" is true of any frame, so the fallback rectangle,
    /// which contains the origin, still catches a mount that forgot to park its window.
    static func displayBounds() -> CGRect {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        return union.isNull ? CGRect(x: 0, y: 0, width: 4000, height: 4000) : union
    }

    /// A point far enough below-left of every attached display that the card cannot intersect one.
    static func offscreenOrigin() -> CGPoint {
        let bounds = displayBounds()
        return CGPoint(x: bounds.minX - canvas.width - 2000, y: bounds.minY - canvas.height - 2000)
    }

    private func mount(path: String, coverage: FileLocation.Coverage?) -> Inspector {
        let host = NSHostingView(rootView: body(path: path, coverage: coverage))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        // Ordered in, but parked past the edge of every display. The card fills itself from two
        // `.task`s that land after the first render; `settled`'s pump, which yields to the runloop
        // each pass, is what commits them, and being on a display makes no measurable difference.
        // Off screen the card doesn't cover the user's desktop for the whole suite, and the suite
        // runs about 3× faster. `theCardFillsItselfWithTheWindowOffScreen` guards both halves.
        window.setFrameOrigin(Self.offscreenOrigin())
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        return Inspector(host: host, window: window, path: path)
    }

    private func snapshot(_ inspector: Inspector) -> NSBitmapImageRep? {
        inspector.host.layoutSubtreeIfNeeded()
        guard let rep = inspector.host.bitmapImageRepForCachingDisplay(in: inspector.host.bounds)
        else { return nil }
        inspector.host.cacheDisplay(in: inspector.host.bounds, to: rep)
        return rep
    }

    /// How many sampled pixels differ. Reads `bitmapData` directly: `colorAt(x:y:)` allocates an
    /// `NSColor` per pixel, and comparing a 320×1400 card dozens of times per case would stretch the
    /// suite to minutes and keep the settle loop from polling often enough.
    private func pixelsDiffering(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        guard let a = lhs.bitmapData, let b = rhs.bitmapData,
              lhs.bytesPerRow == rhs.bytesPerRow,
              lhs.pixelsHigh == rhs.pixelsHigh, lhs.pixelsWide == rhs.pixelsWide,
              lhs.samplesPerPixel == rhs.samplesPerPixel
        else { return Int.max }   // shapes disagree: not comparable, never silently "identical"
        let samples = lhs.samplesPerPixel
        let rowBytes = lhs.bytesPerRow
        // 5/255, about a 0.02 float threshold: enough to ignore compositing noise, far below any
        // glyph.
        let tolerance = 5
        var differing = 0
        for y in stride(from: 0, to: lhs.pixelsHigh, by: 2) {
            let row = y * rowBytes
            for x in stride(from: 0, to: lhs.pixelsWide, by: 2) {
                let i = row + x * samples
                if abs(Int(a[i]) - Int(b[i])) > tolerance
                    || abs(Int(a[i + 1]) - Int(b[i + 1])) > tolerance
                    || abs(Int(a[i + 2]) - Int(b[i + 2])) > tolerance {
                    differing += 1
                }
            }
        }
        return differing
    }

    /// Waits for the card to stop changing, then returns what it paints. Bounded by
    /// `LayoutPumpWait`, which floors on passes, not seconds, and reports the pass count on failure:
    /// the card's `.task`s land on main-actor turns, which a wall-clock deadline starves under load
    /// (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps").
    ///
    /// Quiet means `stableFrames` consecutive identical frames, not one matching pair: the card
    /// lands in stages (metadata and icon, the materialization stat, a folder's size walk), and two
    /// matching frames easily fall in a gap between stages.
    @discardableResult
    private func settled(_ inspector: Inspector, stableFrames: Int = 4,
                         within timeout: TimeInterval = 15,
                         _ what: String,
                         sourceLocation: SourceLocation = #_sourceLocation) async -> NSBitmapImageRep? {
        var previous: NSBitmapImageRep?
        var latest: NSBitmapImageRep?
        var quiet = 0
        let (held, pumps) = await LayoutPumpWait.pump(inspector.host, upTo: timeout) {
            guard let current = snapshot(inspector) else { return false }
            if let previous, pixelsDiffering(previous, current) == 0 { quiet += 1 } else { quiet = 0 }
            previous = current
            latest = current
            return quiet >= stableFrames
        }
        #expect(held, "\(what) — still moving after \(pumps) layout passes",
                sourceLocation: sourceLocation)
        return latest ?? snapshot(inspector)
    }

    /// Swaps the coverage on an already-loaded card and returns what it paints next.
    private func repaint(_ inspector: Inspector, coverage: FileLocation.Coverage?,
                         _ what: String,
                         sourceLocation: SourceLocation = #_sourceLocation) async -> NSBitmapImageRep? {
        inspector.host.rootView = body(path: inspector.path, coverage: coverage)
        inspector.host.layoutSubtreeIfNeeded()
        return await settled(inspector, what, sourceLocation: sourceLocation)
    }

    /// The card still fills itself with its window off every display, and the window stays off
    /// them: the premise the other layout cases rest on.
    ///
    /// The first frame is the empty, still-loading card, so any difference from the settled one
    /// came through the `.task`s. `LayoutPumpWait.pump` returning without pumping must fail it.
    ///
    /// The second half stops "ordered in" being read as "visible": a frame that intersects any
    /// display, parked wrongly or pulled back by AppKit, fails here instead of painting over the
    /// user's screen. A plain `orderBack` without parking must fail it.
    @Test(.machinePinned(.pixelSampling)) func theCardFillsItselfWithTheWindowOffScreen() async throws {
        let root = try fixture("WhereItLivesOffScreen")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.md")
        try Data("x".utf8).write(to: file)

        let inspector = mount(path: file.path, coverage: .empty)
        let first = try #require(snapshot(inspector))
        let landed = try #require(await settled(inspector, "the card never settled"))

        #expect(pixelsDiffering(first, landed) > 0,
                "nothing arrived after the first frame — the offscreen window is not rendering the card's async state")
        let frame = inspector.window.frame
        #expect(NSScreen.screens.allSatisfy { !$0.frame.intersects(frame) },
                "the card's window is sitting on a display at \(frame) — it would cover the user's screen")
        // For a host with no displays, where `allSatisfy` above is true of anything.
        // `displayBounds()` is never empty, so this can't pass vacuously.
        #expect(!Self.displayBounds().intersects(frame),
                "the card's window at \(frame) is inside \(Self.displayBounds()) — it was not parked off the displays")
    }

    /// A file inside a cloud folder and one outside lay out differently. One card, one load; only
    /// the coverage changes, so the delta is the verdict row. The file is real, so the real `lstat`
    /// answers `false`: `This Mac · <provider>` against `This Mac only`.
    @Test(.machinePinned(.pixelSampling)) func theVerdictChangesWithTheCoverage() async throws {
        let root = try fixture("WhereItLives")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Q3 Forecast.numbers")
        try Data("x".utf8).write(to: file)

        let covered = FileLocation.coverage(
            of: [CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud",
                               rootPath: root.path, type: .iCloud)],
            disabledProviderIds: [])

        let inspector = mount(path: file.path, coverage: .empty)
        let outside = try #require(await settled(inspector, "the card never settled"))
        let inside = try #require(await repaint(inspector, coverage: covered,
                                                "the card never settled after the coverage changed"))
        #expect(pixelsDiffering(outside, inside) > 0,
                "the same file laid out identically inside and outside a cloud folder — the verdict is not being drawn")
    }

    /// An unknown coverage draws no verdict rather than falling back to "This Mac only". That is
    /// why the parameter is Optional: `.empty` claims no cloud folder contains anything, so
    /// defaulting to it would place every iCloud file on this Mac only.
    ///
    /// `.empty`, not `.none`: `Coverage.none` at an Optional call site resolves to `Optional.none`
    /// and silently becomes `nil`, the very confusion under test.
    @Test(.machinePinned(.pixelSampling)) func anUnknownCoverageDrawsNoVerdictRatherThanTheWrongOne() async throws {
        let root = try fixture("WhereItLivesUnknown")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.md")
        try Data("x".utf8).write(to: file)

        let inspector = mount(path: file.path, coverage: nil)
        let unknown = try #require(await settled(inspector, "the card never settled"))
        let empty = try #require(await repaint(inspector, coverage: .empty,
                                               "the card never settled after the coverage changed"))
        #expect(pixelsDiffering(unknown, empty) > 0,
                "an unknown coverage laid out the same as a proven-empty one — one of them is claiming something it cannot")
    }

    /// A folder's card says where it is, and nothing about its content. Moved inside a cloud
    /// folder, the card changes: *Where it lives* answers for a folder by containment alone ("In
    /// iCloud", "This Mac only"). *On this Mac* never appears for a folder;
    /// `aFolderIsNeverToldItsContentIsOrIsNotHere` pins that.
    @Test(.machinePinned(.pixelSampling)) func aFoldersCardSaysWhereItIsFromCoverageAlone() async throws {
        let root = try fixture("WhereItLivesFolder")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Inner")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let covered = FileLocation.coverage(
            of: [CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud",
                               rootPath: root.path, type: .iCloud)],
            disabledProviderIds: [])

        let inspector = mount(path: folder.path, coverage: .empty)
        let outside = try #require(await settled(inspector, "the folder card never settled"))
        let inside = try #require(await repaint(inspector, coverage: covered,
                                                "the folder card never settled after the coverage changed"))
        #expect(pixelsDiffering(outside, inside) > 0,
                "a folder's card said nothing about where it is — the ⌂ badge's answer has nowhere left to live")
    }

    /// The row's words for a folder, and that a file's are unchanged: containment for a folder, with
    /// no stat to wait for; the verdict for a file, once its answer is in; nothing without coverage.
    @Test func aFolderLivesWhereItsContainmentSays() {
        let cloud = "/Users/u/Library/Mobile Documents/com~apple~CloudDocs"
        let coverage = FileLocation.coverage(
            of: [CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud",
                               rootPath: cloud, type: .iCloud)],
            disabledProviderIds: [])
        func text(_ path: String, folder: Bool, _ coverage: FileLocation.Coverage?,
                  isCloudOnly: Bool? = nil, hasAnswer: Bool = false) -> String? {
            DetailsSidebar.whereItLivesText(path: path, isDirectory: folder, coverage: coverage,
                                            isCloudOnly: isCloudOnly, hasAnswer: hasAnswer)
        }
        #expect(text("\(cloud)/Taxes", folder: true, coverage) == "In iCloud")
        #expect(text("/Users/u/Projects", folder: true, coverage) == "This Mac only")
        #expect(text("/Users/u/Projects", folder: true, nil) == nil, "a folder was judged with no coverage to judge by")
        #expect(text("/Users/u/Projects/a.txt", folder: false, coverage) == nil, "a file was judged before its stat")
        #expect(text("/Users/u/Projects/a.txt", folder: false, coverage, isCloudOnly: false, hasAnswer: true)
                == "This Mac only")
        #expect(text("\(cloud)/a.txt", folder: false, coverage, isCloudOnly: true, hasAnswer: true) == "iCloud only")
    }
}
