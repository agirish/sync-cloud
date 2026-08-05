import Testing
import AppKit
import SwiftUI
import Sync
@testable import Dashboard

/// The Info inspector's *Where it lives* rows: the supporting "On this Mac" fact and the verdict
/// beneath it.
///
/// Two layers, because they fail differently. The wording is a pure function and is pinned
/// exhaustively — including the states a real filesystem cannot be made to produce. What the card
/// actually LAYS OUT is pinned by mounting it over real files, so the plumbing between the stat,
/// the state and the row has to work.
/// `.serialized` because the layout cases order a real window front to make SwiftUI render their
/// async-loaded state (see `mount`). Two suites doing that at once trade focus and repaint each
/// other's windows, which no amount of settling can wait out.
@MainActor
@Suite(.serialized) struct DetailsWhereItLivesTests {

    // MARK: The supporting fact — every state, including the unproducible ones

    /// A downloaded file says so.
    @Test func aDownloadedFileSaysItIsOnThisMac() {
        #expect(DetailsSidebar.onThisMacText(isDirectory: false, isCloudOnly: false,
                                             hasAnswer: true) == "Yes — downloaded")
    }

    /// A dataless placeholder says so — and says it as a fact about the content, not a warning.
    @Test func aPlaceholderSaysTheContentIsNotHere() {
        #expect(DetailsSidebar.onThisMacText(isDirectory: false, isCloudOnly: true,
                                             hasAnswer: true) == "No — placeholder only")
    }

    /// **Until the `lstat` lands the row is a placeholder, not an answer.** The stat runs off the
    /// main actor precisely because it can block for seconds against a wedged file provider; a row
    /// that guessed "Yes — downloaded" while waiting would be right most of the time and silently
    /// wrong exactly when the answer mattered.
    @Test func anUnresolvedRowSaysItIsStillChecking() {
        #expect(DetailsSidebar.onThisMacText(isDirectory: false, isCloudOnly: nil,
                                             hasAnswer: false) == "Checking…")
    }

    /// **A stat that could not answer draws nothing at all.** `isCloudOnlyIfKnown` says nil when
    /// the path cannot be statted — deleted mid-download, or never there — and "not dataless" and
    /// "not there" are opposite facts reported through the same failure. A row reading "Unknown"
    /// would invite the reading that SyncCloud looked and found nothing, when it did not look.
    ///
    /// Distinct from the case above: `hasAnswer` is true here. The stat ran and came back empty.
    @Test func anUnanswerableStatDrawsNoRowAtAll() {
        #expect(DetailsSidebar.onThisMacText(isDirectory: false, isCloudOnly: nil,
                                             hasAnswer: true) == nil)
    }

    /// A folder has no content of its own to be downloaded or not — its children each answer
    /// differently — so it is never told it is "downloaded". Asserted across every materialization
    /// state, so the rule cannot hold for one of them by accident.
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

    /// Tall on purpose. The inspector is a `ScrollView`, so anything past the bottom of the frame
    /// is simply not painted — and the *Where it lives* rows sit below the Path row, whose value
    /// is a full absolute path that wraps over several lines at this width. At 560pt the new rows
    /// fell off the canvas and every pixel comparison here read zero difference: a test measuring
    /// the wrong part of the card, not a feature that was missing.
    private static let canvas = CGSize(width: 320, height: 1400)

    private func fixture(_ prefix: String) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// One mounted inspector, kept alive with the window it paints into.
    ///
    /// **The coverage is swapped ON this host rather than compared across two of them**, and that
    /// is the whole design of these cases. Two separate mounts each spend their first frames
    /// loading, off their own clocks; comparing them measures whatever stage each happened to
    /// reach as much as it measures the rows. Both failure directions were observed here — a
    /// "poll until it differs from the other host" form passed with the rows deleted outright, and
    /// a settle-then-compare form later reported a difference between two cards that should have
    /// been identical. One host, loaded once, with only `cloudCoverage` changing afterwards, has
    /// neither problem: the delta can only be the rows.
    ///
    /// Assigning `rootView` is an update to the same view, not a new one — the structural identity
    /// is unchanged, so `@State` (and with it the landed metadata and materialization answers)
    /// survives the swap.
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
                               compact: true, overridePath: path, singleSource: false,
                               cloudCoverage: coverage)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
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
        // On screen, but at the BACK. This card fills itself from two `.task`s that land after the
        // first render, and SwiftUI does not render those state changes into the backing store of
        // a window that was never ordered in at all — measured here, a real file's card came back
        // pixel-identical to a nonexistent path's empty state. `orderBack` is enough to get the
        // rendering; `orderFrontRegardless` would also take focus from whatever else is running,
        // which is a poor thing for a test to do to the machine.
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

    /// How many sampled pixels differ.
    ///
    /// Reads `bitmapData` directly rather than calling `colorAt(x:y:)`. That convenience allocates
    /// an `NSColor` per pixel, and this suite compares a 320×1400 card dozens of times per case —
    /// it took the suite from a few seconds to three minutes on its own. The raw form is the same
    /// comparison at a fraction of the cost, which is what lets the settle loop poll often enough
    /// to be trustworthy.
    private func pixelsDiffering(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        guard let a = lhs.bitmapData, let b = rhs.bitmapData,
              lhs.bytesPerRow == rhs.bytesPerRow,
              lhs.pixelsHigh == rhs.pixelsHigh, lhs.pixelsWide == rhs.pixelsWide,
              lhs.samplesPerPixel == rhs.samplesPerPixel
        else { return Int.max }   // shapes disagree: not comparable, never silently "identical"
        let samples = lhs.samplesPerPixel
        let rowBytes = lhs.bytesPerRow
        // 5/255 ≈ the 0.02 float threshold the earlier form used — enough to ignore compositing
        // noise, far below any glyph.
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

    /// Waits for the card to stop changing, then returns what it paints.
    ///
    /// **Bounded by `LayoutPumpWait`, which floors on PASSES rather than seconds**, and it reports
    /// the pass count on failure. Both of this card's `.task`s land on main-actor turns, and under
    /// full-suite congestion a wall-clock deadline buys fewer of those exactly when more are
    /// needed — see `docs/flaky-tests.md`, mechanism 2.
    ///
    /// Quiet means `stableFrames` consecutive identical frames, not one matching pair: the card
    /// lands in stages (metadata and icon, then the materialization stat, then a folder's size
    /// walk), and two matching frames fall inside a gap between two of them easily.
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

    /// **A file inside a cloud folder and one outside it lay out differently.** One card, one file,
    /// one load — only the coverage changes, so the delta is the verdict row and nothing else.
    ///
    /// The file is real, so the materialization half is the real `lstat` answering `false`: this is
    /// `This Mac · <provider>` against `This Mac only`.
    @Test func theVerdictChangesWithTheCoverage() async throws {
        let root = try fixture("WhereItLives")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Q3 Forecast.numbers")
        try Data("x".utf8).write(to: file)

        let covered = FileLocation.coverage(
            of: [CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud",
                               path: root.path, type: .iCloud)],
            disabledProviderIds: [])

        let inspector = mount(path: file.path, coverage: .empty)
        let outside = try #require(await settled(inspector, "the card never settled"))
        let inside = try #require(await repaint(inspector, coverage: covered,
                                                "the card never settled after the coverage changed"))
        #expect(pixelsDiffering(outside, inside) > 0,
                "the same file laid out identically inside and outside a cloud folder — the verdict is not being drawn")
    }

    /// **An unknown coverage draws no verdict — it does not fall back to "This Mac only".**
    ///
    /// This is the difference between `nil` and `.empty`, and the reason the parameter is Optional.
    /// An empty coverage is a positive claim that no cloud folder contains anything, so defaulting
    /// to it would report every file in iCloud as being in one place. Absent must be absent.
    ///
    /// (`.empty`, not `.none`: `Coverage.none` written at an Optional call site resolves to
    /// `Optional.none` and silently becomes `nil` — which is exactly the confusion under test.)
    @Test func anUnknownCoverageDrawsNoVerdictRatherThanTheWrongOne() async throws {
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

    /// **A folder's card does not move with the coverage**, because neither row is drawn for one.
    ///
    /// The same card, under two coverages that a FILE lays out differently under
    /// (`theVerdictChangesWithTheCoverage` is the premise, and it is what stops this from being a
    /// claim about a card that never changes at all). Comparing a folder card against a file card
    /// would prove nothing — they differ in name, kind and size before any of this is reached.
    @Test func aFoldersCardDoesNotMoveWithTheCoverage() async throws {
        let root = try fixture("WhereItLivesFolder")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Inner")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let covered = FileLocation.coverage(
            of: [CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud",
                               path: root.path, type: .iCloud)],
            disabledProviderIds: [])

        let inspector = mount(path: folder.path, coverage: .empty)
        let outside = try #require(await settled(inspector, "the folder card never settled"))
        let inside = try #require(await repaint(inspector, coverage: covered,
                                                "the folder card never settled after the coverage changed"))
        #expect(pixelsDiffering(outside, inside) == 0,
                "a folder was given a Where it lives verdict — it has no content of its own for one to be about")
    }
}
