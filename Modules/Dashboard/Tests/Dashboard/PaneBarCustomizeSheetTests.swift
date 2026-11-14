import AppKit
import SwiftUI
import Testing
@testable import Dashboard

/// The customize sheet, as far as a test host can see it: that it lays out, and that every palette
/// tile is an item the bar can place. Not a click-through: the drags and drop targets need a real
/// event loop, and a test that pretended otherwise would be a false green. What is checked is
/// composition and geometry.
@MainActor
@Suite(.serialized) struct PaneBarCustomizeSheetTests {

    /// Renders the sheet against an injected defaults domain. Without it the sheet's `@AppStorage`
    /// reads `UserDefaults.standard`, the arrangement on the machine running the tests, so a
    /// customized bar would render a different sheet from CI's.
    private func laidOut(_ view: some View) -> CGSize {
        let defaults = ScratchDefaults("PaneBarCustomizeSheetTests-layout")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        return ProbeRig(AnyView(view.defaultAppStorage(defaults)), size: CGSize(width: 600, height: 800)).host.fittingSize
    }

    @Test func testItemsTheEditingPaneCannotDrawAreStillOfferedButMarked() {
        // Collapse Pane is in the default arrangement but only the single-source rail draws it, so
        // a Compare pane's sheet shows a pill its own bar lacks. The arrangement is shared, so that
        // is right, but the sheet must explain it rather than look broken.
        let comparePane = PaneBarCustomizeSheet(
            availableHere: [.viewMode, .backForward, .scan, .newFolder, .sort, .hiddenFiles])
        #expect(comparePane.explainsItemsFromElsewhere,
                "a pane that cannot draw Collapse or Preview showed no explanation for them")

        let everything = PaneBarCustomizeSheet(availableHere: Set(PaneBarItem.allCases))
        #expect(!everything.explainsItemsFromElsewhere,
                "a pane that can draw everything still spent space explaining nothing")
    }

    @Test func testTheSheetLaysOutAtAWorkableSize() {
        let size = laidOut(PaneBarCustomizeSheet())
        // 600 is the sheet's declared width, which the track's metrics are sized to. It stays
        // under the window's minimum width, so the sheet never outgrows its window.
        #expect(size.width == 600, "the sheet should hold its declared width, got \(size.width)")
        // Tall enough to be a real sheet, short enough not to run off a laptop screen.
        #expect(size.height > 300 && size.height < 760, "sheet height \(size.height) is out of range")
    }

    @Test func testThePaletteListsEachItemOnce() {
        let palette = PaneBarCustomizeSheet.palette
        #expect(Set(palette).count == palette.count, "the palette repeats an item")
    }

    @Test func testThePaletteOffersEveryRemovableControl() {
        // The direction that rots: a new control with no tile can never be put back once removed.
        for item in PaneBarItem.allCases where !item.isSpacer {
            #expect(PaneBarCustomizeSheet.palette.contains(item),
                    "\(item.displayName) can be on the bar but has no palette tile")
        }
    }

    @Test func testEveryPaletteGlyphIsARealSFSymbol() {
        // A misspelled symbol name fails nowhere: it draws nothing and the tile becomes a labelled
        // blank. `PaneGlyphTests` pins the pane's other glyphs for the same reason.
        for item in PaneBarItem.allCases {
            #expect(NSImage(systemSymbolName: item.paletteSymbol, accessibilityDescription: nil) != nil,
                    "\(item.displayName) names a symbol that does not exist: \(item.paletteSymbol)")
        }
    }

    @Test func testScanIsOfferedButInert() {
        // Offered so its absence from the removable set is visible, not a control someone hunts for.
        #expect(!PaneBarItem.scan.isRemovable)
    }

    // MARK: Can you actually aim at it

    /// Right-clicks the centre of one track pill and returns the menu, if any. The one interaction
    /// here a test can drive: SwiftUI answers `NSView.menu(for:)` by hit-testing the point, so the
    /// menu shows whether the pill is aimable. A pill drawn as an unfilled outline is hit-testable
    /// only along the outline.
    private func menuAtCentre(of item: PaneBarItem) -> NSMenu? {
        let defaults = ScratchDefaults("PaneBarCustomizeSheetTests-aim")
        defaults.set(PaneBarArrangement([.space, .scan, .flexibleSpace, .sort]).encoded,
                     forKey: PaneBar.arrangementKey)
        let sheet = PaneBarCustomizeSheet()
        let host = NSHostingView(rootView: AnyView(sheet.trackItem(item, at: 0)
                                                       .defaultAppStorage(defaults)))
        // Borderless and never ordered in: `constrainFrameRect` drags a `.titled` window back on
        // screen, over whatever the user is doing.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        let centre = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown,
                                             location: host.convert(centre, to: nil),
                                             modifierFlags: [],
                                             timestamp: 0,
                                             windowNumber: window.windowNumber,
                                             context: nil,
                                             eventNumber: 0,
                                             clickCount: 1,
                                             pressure: 1) else {
            Issue.record("could not synthesize a right-click")
            return nil
        }
        return host.menu(for: event)
    }

    /// The head of the track is a blank drop zone, not a provider capsule, which the real bar
    /// doesn't have. "First" must stay aimable, so the zone keeps a width and paints nothing. It
    /// lies over the track's leading padding, so its width indents nothing. The control is a fixed
    /// space's pill, the faintest thing on the track: a probe that sees it would see a capsule.
    @Test func theHeadOfTheTrackIsABlankDropZone() throws {
        let sheet = PaneBarCustomizeSheet()
        let zone = NSHostingView(rootView: AnyView(sheet.leadingEdgeZone))
        #expect(zone.fittingSize.width >= 8,
                "the leading drop zone is \(zone.fittingSize.width)pt wide — too thin to aim a drop at")
        #expect(zone.fittingSize.width <= 10,
                "the leading drop zone is \(zone.fittingSize.width)pt wide — wider than the padding it lies on")

        let blank = try #require(Self.inkedPixels(sheet.leadingEdgeZone))
        let control = try #require(Self.inkedPixels(sheet.trackItem(.space, at: 0)))
        #expect(control > 20, "the probe saw \(control) inked pixels on a space pill — it is blind")
        #expect(blank == 0, "the leading drop zone painted \(blank) pixels; it should draw nothing")
    }

    /// The head's zone scrolls with the row. Laid over the `ScrollView` it would stay pinned at the
    /// visible left edge, and on a scrolled long bar a drop there would land at index 0, off screen.
    /// A drop can't be driven from a test, so this reads `track`: the zone must be inside the scroll
    /// view's content closure, and nowhere after it.
    @Test func theHeadZoneIsScrolledContent() throws {
        let code = try DashboardSource.read("PaneBarCustomizeSheet.swift", codeOnly: true)
        let start = try #require(code.range(of: "private var track: some View {"))
        let end = try #require(code.range(of: "private var trackRow: some View {", range: start.upperBound..<code.endIndex))
        let track = code[start.upperBound..<end.lowerBound]
        let open = try #require(track.range(of: "ScrollView(.horizontal"), "track no longer scrolls — re-read this test")
        // The content closure ends at the first brace back at the ScrollView's own indent.
        let close = try #require(track.range(of: "\n        }", range: open.upperBound..<track.endIndex))
        #expect(track[open.upperBound..<close.lowerBound].contains("leadingEdgeZone"),
                "the head's drop zone is not inside the scrolled content — it stays at the visible edge")
        #expect(!track[close.upperBound...].contains("leadingEdgeZone"),
                "the head's drop zone is laid over the scroll view, pinned at the visible edge")
    }

    /// Pixels that differ from the white ground, for a view rendered in a real (never shown) window.
    private static func inkedPixels(_ view: some View) -> Int? {
        let host = NSHostingView(rootView: AnyView(view.background(Color.white)
                                                       .environment(\.colorScheme, .light)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        var inked = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.redComponent < 0.97 || c.greenComponent < 0.97 || c.blueComponent < 0.97 { inked += 1 }
            }
        }
        return inked
    }

    @Test func theSpaceOnTheTrackCanBeAimedAt() {
        // A spacer's pill is a dashed outline; with an empty fill its drag, drop and context menu
        // sit on a 1pt ring and a click in the middle falls through to the track. Nothing else
        // removes a space (no palette check, and Restore is all-or-nothing), so it would be stuck on
        // the bar. Both spacers, since their fills differ.
        for spacer in [PaneBarItem.space, .flexibleSpace] {
            let titles = menuAtCentre(of: spacer)?.items.map(\.title) ?? []
            #expect(titles.contains("Remove"),
                    "right-clicking the centre of \(spacer.displayName) offered \(titles); with no Remove there is no way to take it off the bar")
        }
    }

    @Test func soCanAControl() {
        // Control pills sit on a filled capsule. This control shows the probe works, so a failure
        // above means "the space is unaimable", not "the probe measures nothing".
        let titles = menuAtCentre(of: .sort)?.items.map(\.title) ?? []
        #expect(titles.contains("Remove"), "a control pill offered \(titles)")
    }

    /// Every edit this sheet makes goes through `commit`, which logs it. A source scan, because the
    /// five gestures that change the bar (a `Button` action, three drop handlers and an
    /// accessibility action) can't be driven by a unit test. What can be checked is that the whole
    /// product writes the stored arrangement in one place, inside `commit`, so a new gesture that
    /// writes it directly fails here instead of going unlogged.
    ///
    /// Scanned by the key across every source file, not by a variable name in one file: a write can
    /// be spelled `set(…, forKey: PaneBar.arrangementKey)` or `$binding.wrappedValue =`, and
    /// `DashboardViews.swift` binds the same `@AppStorage` key.
    @Test func testTheSheetWritesTheArrangementInExactlyOnePlace() throws {
        let writers = try Self.arrangementWrites()
        // Roots first: a scan with an empty file list or anchor would report "no stray writes" for
        // free.
        #expect(Self.productionSources.count > 1,
                "the repo-wide scan found \(Self.productionSources.count) source files")
        #expect(Self.productionSources.contains { $0.lastPathComponent == "PaneBarCustomizeSheet.swift" },
                "the customize sheet is not in the scanned set, so its own writes are invisible here")
        #expect(Self.productionSources.contains { $0.lastPathComponent == "DashboardViews.swift" },
                "DashboardViews holds the same @AppStorage key and is not in the scanned set")
        // The known bindings. If the declaration scan stopped finding them, every assignment count
        // below would be zero.
        let bound = Self.arrangementBindings.map { "\($0.0.lastPathComponent).\($0.1)" }
        let bindingsChanged = "the files binding @AppStorage(PaneBar.arrangementKey) changed: \(bound)"
        #expect(Self.arrangementBindings.map { $0.0.lastPathComponent }.sorted()
                == ["DashboardViews.swift", "PaneBarCustomizeSheet.swift"], "\(bindingsChanged)")

        let strayWrites = "\(writers.count) places write the stored pane-bar arrangement — "
            + "\(writers). Every edit must go through PaneBarCustomizeSheet.commit(_:), which is "
            + "the only thing that logs it; the migration's own write is the one exemption and is "
            + "listed in `exempt` with its reason."
        #expect(writers.count == 1, "\(strayWrites)")

        // …and that one is inside `commit`, not merely somewhere in the file. The body ends at the
        // first closing brace at member indent.
        let sheet = try DashboardSource.read("PaneBarCustomizeSheet.swift")
        let commitStart = try #require(sheet.range(of: "private func commit(_ next: PaneBarArrangement)"),
                                       "the funnel is gone or renamed; this scan is vacuous without it")
        let tail = sheet[commitStart.upperBound...]
        let bodyEnd = tail.range(of: "\n    }")?.upperBound ?? tail.endIndex
        let body = tail[..<bodyEnd]
        #expect(body.contains("arrangementRaw = next.encoded"),
                "the single arrangement write is not inside commit(_:)")
        // And that write is logged: deleting the `PaneBarEditLog.record` call from `commit` must
        // fail here, since nothing else would notice.
        let unlogged = "commit(_:) writes the arrangement without logging it, so every gesture in "
            + "this sheet is silent and PaneBarEditLog has no caller at all"
        #expect(body.contains("PaneBarEditLog.record(from: before, to: next)"), "\(unlogged)")
    }

    /// Every write of the stored pane-bar arrangement in the product, as `file: line` strings. Two
    /// spellings:
    ///
    /// * an assignment to a property bound with `@AppStorage(PaneBar.arrangementKey)`, in whichever
    ///   file declares it, including through `$binding.wrappedValue`;
    /// * a `set(…, forKey:)` naming the key or its literal, anywhere.
    ///
    /// `PaneBarMigration.apply`'s write in `PaneBarArrangement.swift` is exempt: it runs before any
    /// `@AppStorage` wrapper reads the bar, isn't a user edit, and logs its own launch line.
    ///
    /// Blind spots: a key passed through a local (`let k = PaneBar.arrangementKey`), or
    /// `setPersistentDomain`. Nothing in the repo writes the key either way.
    private static func arrangementWrites() throws -> [String] {
        /// The migration's own write, quoted exactly. Exempt by its whole text and its file, so a
        /// second write added to `PaneBarArrangement.swift` is still reported.
        let exempt = ("PaneBarArrangement.swift",
                      "defaults.set(arrangement.encoded, forKey: PaneBar.arrangementKey)")
        var writes: [String] = []
        for url in productionSources {
            let bindings = arrangementBindings.filter { $0.0 == url }.map(\.1)
            for line in try readStrippingComments(url).split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                // `hasSuffix` as well as `contains`, to catch an assignment whose value sits on the
                // next line, as both declaring files write it.
                let assigns = bindings.contains {
                    text.contains("\($0) = ") || text.hasSuffix("\($0) =")
                        || text.contains("$\($0).wrappedValue = ")
                        || text.hasSuffix("$\($0).wrappedValue =")
                }
                // `.set(` is what separates a write from `string(forKey:)` and friends.
                let stores = text.contains(".set(")
                    && (text.contains("forKey: PaneBar.arrangementKey")
                        || text.contains(#"forKey: "paneBarArrangement""#))
                guard assigns || stores else { continue }
                guard !(url.lastPathComponent == exempt.0 && text == exempt.1) else { continue }
                writes.append("\(url.lastPathComponent): \(text)")
            }
        }
        return writes
    }

    /// Every file declaring `@AppStorage(PaneBar.arrangementKey)`, with the property's name.
    private static let arrangementBindings: [(URL, String)] = {
        var found: [(URL, String)] = []
        for url in productionSources {
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                  source.contains("@AppStorage(PaneBar.arrangementKey)") else { continue }
            var rest = Substring(source)
            while let hit = rest.range(of: "@AppStorage(PaneBar.arrangementKey)") {
                let after = rest[hit.upperBound...]
                if let varKeyword = after.range(of: "var ") {
                    let name = after[varKeyword.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    found.append((url, String(name)))
                }
                rest = rest[hit.upperBound...]
            }
        }
        return found
    }()

    /// Every non-test Swift file under `Modules`, `MacApp` and `SyncCloudCLI`. Repo-wide because
    /// the key is `public` and any module could write it. Tests are excluded: they set the key on
    /// scratch domains all the time.
    private static let productionSources: [URL] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/Dashboard
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/Dashboard
            .deletingLastPathComponent()   // …/Modules
            .deletingLastPathComponent()   // repo root
        var urls: [URL] = []
        for top in ["Modules", "MacApp", "SyncCloudCLI"] {
            let base = root.appendingPathComponent(top)
            guard let walk = FileManager.default.enumerator(at: base,
                                                            includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                guard !url.path.contains("/Tests/") else { continue }
                urls.append(url)
            }
        }
        return urls
    }()

    /// Source with whole-line comments removed: comments quote the very spellings being counted.
    private static func readStrippingComments(_ url: URL) throws -> String {
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read \(url.lastPathComponent) — this scan would be vacuous")
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
