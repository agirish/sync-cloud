import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// What the header claims about a query, on the pages that answer one and the two that don't.
///
/// `searchQueries` is `@State` seeded empty and SwiftUI can't be driven from a unit test, so only
/// `LensWorkspaceView.init`'s `initialSearchQueries` seam lets a test render a live query. Pinned:
///
///   * Organize's overview filters and counts nothing, so it shows no field, chips or "N of M".
///   * The rename backlog's query narrows its folded to-fix names as well as its folder plans.
///   * Storage shows no count before a report exists: absent, not "0 of 0".
///
/// Pixels, because nothing else is open: the readout is a `Text` inside the header card,
/// `fittingSize` is the frame whatever it holds, and with no assistive client attached a caption
/// assertion passes whatever the label says.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct LensHeaderReadoutTests {

    private static let canvas = CGSize(width: 720, height: 620)

    // MARK: Fixtures

    private static func suggestion(_ name: String) -> FilingSuggestion {
        FilingSuggestion(
            filePath: "/root/TODO/\(name)", fileName: name, size: 4_096,
            modificationDate: Date(timeIntervalSince1970: 0),
            candidates: [FilingDestination(path: "/root/Documents/Family", confidence: .high,
                                           reasons: ["test"], newSegments: [])],
            providerRoot: "/root")
    }

    /// A completed file pass with two loose files: enough for To File to have a list, and for a
    /// query matching neither to visibly narrow it.
    private static func filingManager() -> FileSyncManager {
        let m = FileSyncManager()
        m.publishFilingSuggestions([suggestion("alpha.pdf"), suggestion("beta.pdf")])
        m.hasSuggestedFiling = true
        m.filingScanFolder = "/root/TODO"
        m.filingLastProviderRoot = "/root"
        return m
    }

    private static func plan(_ relativePath: String) -> RenamePlan {
        RenamePlan(folderPath: "/root/\(relativePath)", relativePath: relativePath,
                   scheme: .position,
                   steps: [RenameStep(currentPath: "/root/\(relativePath)/4. Apr 2021.pdf",
                                      currentName: "4. Apr 2021.pdf",
                                      proposedName: "04. Apr 2021.pdf",
                                      kind: .tidied, reason: "Padded to two digits")],
                   skips: [])
    }

    private static func risky(_ name: String) -> RiskyName {
        RiskyName(id: "/root/Names/\(name)", relativePath: "Names/\(name)", currentName: name,
                  sanitizedName: name.replacingOccurrences(of: ":", with: "-"),
                  reason: "Colons break sync", isDirectory: false)
    }

    /// A completed file pass holding one rename plan and one risky name, the backlog's two halves,
    /// each matching a different word, so a query can be aimed at exactly one of them.
    private static func backlogManager(riskyName: String) -> FileSyncManager {
        let m = FileSyncManager()
        m.hasSuggestedFiling = true
        m.filingScanFolder = "/root"
        m.filingLastProviderRoot = "/root"
        m.publishRenamePlans([plan("alpha-folder")])
        m.riskyNames = [risky(riskyName)]
        return m
    }

    private static func storageManager(withReport: Bool) -> FileSyncManager {
        let m = FileSyncManager()
        guard withReport else { return m }
        let entries = (1...4).map {
            StorageEntry(path: "/root/big\($0).mov", name: "big\($0).mov", bytes: 900_000_000,
                         modified: Date(timeIntervalSince1970: 0))
        }
        m.storageLensReport = StorageLensReport(treemap: [], largest: entries, stale: entries,
                                                reclaimCandidates: entries,
                                                totalBytes: 48_200_000_000,
                                                fileCount: entries.count,
                                                staleCount: entries.count,
                                                reclaimCount: entries.count,
                                                reclaimableBytes: entries.reduce(0) { $0 + $1.bytes })
        return m
    }

    // MARK: Mounting

    private final class Mounted {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let defaults: ScratchDefaults
        init(host: NSHostingView<AnyView>, window: NSWindow, defaults: ScratchDefaults) {
            self.host = host
            self.window = window
            self.defaults = defaults
        }
    }

    /// Mounts Organize (or Storage) standing on `rail`, with `queries` already parked. The rail
    /// selection goes through a fresh `ScratchDefaults`, not `UserDefaults.standard`: other suites
    /// in this target write that key, in parallel, so every render here would race them.
    private func mount(_ manager: FileSyncManager, lens: WorkspaceLensKind = .filing,
                       rail: OrganizeLens?, queries: [WorkspaceLensKind: String]) -> Mounted {
        let defaults = ScratchDefaults("LensHeaderReadoutTests")
        if let rail { defaults.set(rail.rawValue, forKey: OrganizeLens.defaultsKey) }
        let subject = LensWorkspaceView(syncManager: manager, lens: lens,
                               providerName: "Projects", scanTargetFolder: "/root",
                               onFindDuplicates: {}, initialSearchQueries: queries)
            .defaultAppStorage(defaults)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        // Without a window the content composites against the borderless window's own buffer and
        // every comparison reads as zero difference, whatever the code did.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return Mounted(host: host, window: window, defaults: defaults)
    }

    /// Every capture in this suite goes through here, and it resigns first responder before it
    /// draws. That is load-bearing, not hygiene.
    ///
    /// A mount with a parked query renders its search field open, and `ExpandingSearchField`
    /// claims focus for it on appear. AppKit select-alls a text field that becomes first responder,
    /// so the query is painted behind a selection band (about 4500 pixels here). SwiftUI arbitrates
    /// that focus process-wide: any other suite handing an `NSTextField` first responder, or this
    /// test's own second mount, evicts it on the next layout pass, band and all, so a comparison of
    /// two mounts would read the process's focus history, not the screen (`docs/flaky-tests.md`,
    /// "Text-field focus is arbitrated process-wide, so any suite can evict another's field editor
    /// — FIXED").
    ///
    /// It hides no instability: a mount stays byte-identical across 400 fixed layout passes (count
    /// them with a fixed loop, not a time-bounded pump), and a re-claim between frames would keep
    /// `settled` from going quiet rather than pass an equality.
    private func snapshot(_ m: Mounted, _ band: CGRect? = nil) -> NSBitmapImageRep? {
        m.window.makeFirstResponder(nil)
        m.host.layoutSubtreeIfNeeded()
        let rect = band ?? m.host.bounds
        guard let rep = m.host.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        m.host.cacheDisplay(in: rect, to: rep)
        return rep
    }

    /// Pixels whose red, green or blue moved by more than 5 of 255 (0.02) in the 8-bit samples
    /// every capture here holds.
    ///
    /// Read from the bytes, skipping rows whose bytes match, because this is the suite's whole
    /// cost: a settled frame matches its predecessor byte for byte, so most comparisons are one
    /// `memcmp` per row, where `colorAt(x:y:)` per pixel would dominate the main thread
    /// (`docs/flaky-tests.md`, "A pixel probe that calls `colorAt` per pixel, so load stretches it
    /// into a hang — FIXED"). Rows that differ still get the tolerant test; byte equality alone
    /// could keep `settled` from ever going quiet. Alpha is not compared. Any other layout fails
    /// `Pixel.check` loudly and answers -1, which no assertion here accepts.
    private func pixelsDiffering(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else { return -1 }
        guard Pixel.check(lhs), Pixel.check(rhs), !lhs.isPlanar, !rhs.isPlanar,
              lhs.samplesPerPixel == rhs.samplesPerPixel,
              let a = lhs.bitmapData, let b = rhs.bitmapData else { return -1 }
        let samples = lhs.samplesPerPixel, rowBytes = lhs.pixelsWide * samples
        var differing = 0
        for y in 0..<lhs.pixelsHigh {
            let rowA = a + y * lhs.bytesPerRow, rowB = b + y * rhs.bytesPerRow
            if memcmp(rowA, rowB, rowBytes) == 0 { continue }
            for p in stride(from: 0, to: rowBytes, by: samples)
            where abs(Int(rowA[p]) - Int(rowB[p])) > 5
                || abs(Int(rowA[p + 1]) - Int(rowB[p + 1])) > 5
                || abs(Int(rowA[p + 2]) - Int(rowB[p + 2])) > 5 {
                differing += 1
            }
        }
        return differing
    }

    /// This mount's screen once it has stopped moving. Each mount settles on its own first: a fresh
    /// `NSHostingView` hasn't finished drawing, so two hosts from identical state differ by tens of
    /// thousands of pixels at first. Bounded by `LayoutPumpWait`, which floors on passes.
    private func settled(_ m: Mounted, _ what: String, stableFrames: Int = 4,
                         sourceLocation: SourceLocation = #_sourceLocation) async -> NSBitmapImageRep? {
        var previous: NSBitmapImageRep?
        var latest: NSBitmapImageRep?
        var quiet = 0
        let (held, pumps) = await LayoutPumpWait.pump(m.host, upTo: 10) {
            guard let current = snapshot(m) else { return false }
            if let previous, pixelsDiffering(previous, current) == 0 { quiet += 1 } else { quiet = 0 }
            previous = current
            latest = current
            return quiet >= stableFrames
        }
        #expect(held, "\(what) — still moving after \(pumps) layout passes",
                sourceLocation: sourceLocation)
        return latest ?? snapshot(m)
    }

    // MARK: The overview answers no query

    /// A parked query changes nothing on the overview: no field, no chips, no "N of M". Three rail
    /// items share `.filing`'s query and the overview borrows that apparatus, so a To File query
    /// follows you there; offering it would open the field, grow the card 36pt and count the empty
    /// `rows.filing` against To File's whole list. Equality fails on any visible trace of the query.
    @Test func aParkedQueryLeavesTheOverviewUntouched() async throws {
        let quiet = try #require(await settled(
            mount(Self.filingManager(), rail: nil, queries: [:]), "overview, no query"))
        let queried = try #require(await settled(
            mount(Self.filingManager(), rail: nil, queries: [.filing: "zzz-nothing"]),
            "overview, query parked"))
        let moved = pixelsDiffering(quiet, queried)
        let report = "a query the overview cannot answer changed \(moved) pixels of it — the "
            + "field, the chips or the readout is still being offered"
        #expect(moved == 0, "\(report)")
    }

    /// The control for the case above: the same query on a page that does answer it moves the
    /// screen. Without it, a seam that quietly dropped every query would satisfy that equality with
    /// the whole search feature broken.
    @Test func theSameQueryVisiblyNarrowsToFile() async throws {
        let quiet = try #require(await settled(
            mount(Self.filingManager(), rail: .toFile, queries: [:]), "To File, no query"))
        let queried = try #require(await settled(
            mount(Self.filingManager(), rail: .toFile, queries: [.filing: "zzz-nothing"]),
            "To File, query"))
        #expect(pixelsDiffering(quiet, queried) > 0,
                "the query changed nothing on To File — the fixture is not filtering at all")
    }

    // MARK: The backlog is one list

    /// The query narrows the folded to-fix rows too. Two mounts differ only in the risky name, under
    /// a query matching neither name nor plan: if the rows are drawn the screens differ; filtered,
    /// both show the same "Nothing matches".
    @Test func aQueryHidesTheToFixRowsAsWellAsThePlans() async throws {
        let first = try #require(await settled(
            mount(Self.backlogManager(riskyName: "Q1:report.pdf"), rail: .renames,
                  queries: [.filing: "zzz-nothing"]), "backlog, first risky name"))
        let second = try #require(await settled(
            mount(Self.backlogManager(riskyName: "Statement|March.pdf"), rail: .renames,
                  queries: [.filing: "zzz-nothing"]), "backlog, second risky name"))
        let moved = pixelsDiffering(first, second)
        let report = "the to-fix rows are still on screen under a query matching neither of them "
            + "(\(moved) pixels differ)"
        #expect(moved == 0, "\(report)")
    }

    /// The control: with no query the two names paint differently, so the equality above is a
    /// claim about the filter rather than about two fixtures that were never distinguishable.
    @Test func theTwoRiskyNamesArePaintedDifferentlyWhenNothingHidesThem() async throws {
        let first = try #require(await settled(
            mount(Self.backlogManager(riskyName: "Q1:report.pdf"), rail: .renames, queries: [:]),
            "backlog, first risky name"))
        let second = try #require(await settled(
            mount(Self.backlogManager(riskyName: "Statement|March.pdf"), rail: .renames,
                  queries: [:]), "backlog, second risky name"))
        let report = "the two risky names paint identically — this fixture could never show the "
            + "difference the case above relies on"
        #expect(pixelsDiffering(first, second) > 0, "\(report)")
    }

    // MARK: Storage claims no count before it has a report

    /// Row 2's trailing edge, where the "N of M" sits, derived from `LensHeaderMetrics`: card inset,
    /// padding, row 1 and the row gap. Rows 1 and 2 don't move when the search field opens (the card
    /// grows downward), so the band is stable across the comparison. The host is flipped.
    private static var readoutBand: CGRect {
        let top = LiquidGlass.cardInset + LensHeaderMetrics.padding
            + LensHeaderMetrics.tabRow + LensHeaderMetrics.rowGap
        return CGRect(x: canvas.width - 170, y: top - 4,
                      width: 150, height: LensHeaderMetrics.summaryRow + 8)
    }

    /// Nothing is claimed in the readout's own band until a report exists. Both halves are needed:
    /// with a report a query changes this band (the readout arrives), proving the band holds row 2's
    /// trailing edge; without one the same query must leave it untouched, no "0 of 0". A misplaced
    /// band can't pass quietly, because everything below the header shifts when the field opens.
    @Test func storageOffersNoCountBeforeItHasAReport() async throws {
        func bandDiff(withReport: Bool) async throws -> Int {
            let quiet = mount(Self.storageManager(withReport: withReport), lens: .storage,
                              rail: nil, queries: [:])
            _ = try #require(await settled(quiet, "storage, no query (report: \(withReport))"))
            let queried = mount(Self.storageManager(withReport: withReport), lens: .storage,
                                rail: nil, queries: [.storage: "zzz-nothing"])
            _ = try #require(await settled(queried, "storage, query (report: \(withReport))"))
            let a = try #require(snapshot(quiet, Self.readoutBand))
            let b = try #require(snapshot(queried, Self.readoutBand))
            return pixelsDiffering(a, b)
        }
        let withReport = try await bandDiff(withReport: true)
        let bandReport = "typing a query changed nothing at row 2's trailing edge even with a "
            + "report — the band is not where the readout is drawn, so the case below proves nothing"
        #expect(withReport > 0, "\(bandReport)")
        let withoutReport = try await bandDiff(withReport: false)
        let zeroReport = "the readout drew \(withoutReport) pixels with no report behind it — "
            + "“0 of 0” is a count from a scan that never ran"
        #expect(withoutReport == 0, "\(zeroReport)")
    }
}
