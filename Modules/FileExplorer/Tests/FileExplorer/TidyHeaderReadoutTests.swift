import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// **What the header claims about a query, on the pages that answer one and the two that do not.**
///
/// Three defects lived here, and all three were invisible to every existing suite for the same
/// reason: `searchQueries` is `@State` seeded empty, SwiftUI is undrivable from a unit test, and so
/// *no test had ever rendered this screen with a live query in it*. `TidyView.init`'s
/// `initialSearchQueries` is the seam that fixes that; these are what it buys.
///
///   * Organize's overview drew a live "N of M" over sections it neither filters nor counts —
///     "0 of 24", the 0 being rows it does not draw and the 24 a list it is not showing — with the
///     search field open beside it and working chips under it.
///   * The rename backlog filtered its folder plans and left the folded to-fix names alone, so one
///     list answered one query two different ways.
///   * Storage answered a query with "0 of 0" before any report existed, on the one rail whose own
///     documentation says the count is absent before a report, not zero.
///
/// **Pixels, because nothing else here is open.** The readout is a `Text` inside the header card:
/// `fittingSize` is the frame whatever it holds, and with no assistive client attached to this
/// process a caption assertion passes vacuously whatever the label says.
///
/// `.machinePinned(.pixelSampling)`, like every suite here that reads a live renderer back.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct TidyHeaderReadoutTests {

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

    /// A completed file pass with two loose files — enough for To File to have a list, and for a
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

    /// A completed file pass holding one rename plan and one risky name — the backlog's two halves,
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
                                                totalBytes: 48_200_000_000)
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

    /// Mounts Organize (or Storage) standing on `rail`, with `queries` already parked.
    ///
    /// The rail selection goes through a fresh `ScratchDefaults` and `.defaultAppStorage` rather
    /// than `UserDefaults.standard`: other suites in this target write that key and Swift Testing
    /// runs suites in parallel, so the faithful copy would make every render here race them.
    private func mount(_ manager: FileSyncManager, lens: TidyLens = .filing,
                       rail: OrganizeLens?, queries: [TidyLens: String]) -> Mounted {
        let defaults = ScratchDefaults("TidyHeaderReadoutTests")
        if let rail { defaults.set(rail.rawValue, forKey: OrganizeLens.defaultsKey) }
        let subject = TidyView(syncManager: manager, lens: lens,
                               providerName: "Projects", scanTargetFolder: "/root",
                               onFindDuplicates: {}, initialSearchQueries: queries)
            .defaultAppStorage(defaults)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        // Without a window the content composites against the borderless window's own buffer and
        // every comparison reads as zero difference — "nothing painted", whatever the code did.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return Mounted(host: host, window: window, defaults: defaults)
    }

    private func snapshot(_ m: Mounted, _ band: CGRect? = nil) -> NSBitmapImageRep? {
        m.host.layoutSubtreeIfNeeded()
        let rect = band ?? m.host.bounds
        guard let rep = m.host.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        m.host.cacheDisplay(in: rect, to: rep)
        return rep
    }

    private func pixelsDiffering(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else { return -1 }
        var differing = 0
        for y in 0..<lhs.pixelsHigh {
            for x in 0..<lhs.pixelsWide {
                guard let a = lhs.colorAt(x: x, y: y), let b = rhs.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(a.redComponent - b.redComponent),
                                max(abs(a.greenComponent - b.greenComponent),
                                    abs(a.blueComponent - b.blueComponent)))
                if delta > 0.02 { differing += 1 }
            }
        }
        return differing
    }

    /// This mount's screen once IT has stopped moving.
    ///
    /// **Each mount settles on its own before anything is compared.** Two hosts mounted from
    /// identical state and snapshotted immediately differ by tens of thousands of pixels, because a
    /// fresh `NSHostingView` has not finished drawing — so an equality assertion taken too early
    /// fails for the harness's reasons, and an inequality assertion passes for them. Bounded by
    /// `LayoutPumpWait`, which floors on layout PASSES rather than wall seconds.
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

    /// **A parked query changes nothing on the overview** — no field, no chips, no "N of M".
    ///
    /// The query is To File's (three rail items share `.filing`'s apparatus, and the overview
    /// borrows it too), so before this it followed you onto a page that filters nothing: the field
    /// opened, the card grew by its 36pt, and the readout counted `rows.filing` — which the
    /// overview deliberately leaves empty — against To File's whole list. "0 of 24".
    ///
    /// Equality is the assertion, and it is a strong one: it fails on *any* visible trace of the
    /// query, which is exactly what "the overview does not offer a search" has to mean.
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

    /// The control the case above needs: **the same query on a page that DOES answer it moves the
    /// screen.** Without this, a seam that quietly dropped every query would satisfy the equality
    /// above with the whole search feature broken.
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

    /// **The query narrows the folded to-fix rows too.**
    ///
    /// Two mounts differing only in the risky name's text, under a query that matches neither of
    /// them and neither plan. If the to-fix rows are drawn, the two screens differ — the name is
    /// on them. Filtered, both land on the same "Nothing matches", and the only way to tell the
    /// mounts apart is gone.
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

    /// The control: **with no query the two names paint differently**, so the equality above is a
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

    /// Row 2's trailing edge, where the "N of M" sits.
    ///
    /// Derived from `LensHeaderMetrics` rather than eyeballed: the card floats `cardInset` in,
    /// pads by `padding`, then draws row 1 and the row gap above row 2. Rows 1 and 2 do not move
    /// when the search field opens — the card grows downward — so this band is stable across
    /// exactly the comparison below. The host is flipped, so y counts down from the top.
    private static var readoutBand: CGRect {
        let top = LiquidGlass.cardInset + LensHeaderMetrics.padding
            + LensHeaderMetrics.tabRow + LensHeaderMetrics.rowGap
        return CGRect(x: canvas.width - 170, y: top - 4,
                      width: 150, height: LensHeaderMetrics.summaryRow + 8)
    }

    /// **Nothing is claimed in the readout's own band until a report exists.**
    ///
    /// Both halves are needed and the first is what keeps the second honest: with a report, typing
    /// a query changes this band (the readout arrives, and pushes the controls beside it along), so
    /// the band demonstrably contains row 2's trailing edge. Without a report, the same query must
    /// leave it untouched — no "0 of 0", which is a scan's result reported by a scan that never ran.
    ///
    /// A misplaced band cannot pass this quietly: everything below the header shifts when the
    /// search field opens, so a band pointing anywhere but rows 1–2 fails the second half at once.
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
