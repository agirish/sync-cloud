import AppKit
import SwiftUI
import Testing
@testable import Dashboard

/// The customize sheet, as far as a test host can see it: that it lays out at all, and that every
/// palette tile it offers is an item the bar can actually place.
///
/// Deliberately not a click-through: the drag gestures and the drop targets need a real event loop,
/// and a test that pretended otherwise would be the kind of false green this suite exists to avoid.
/// What is checked here is the part that can be: composition and geometry.
@MainActor
@Suite(.serialized) struct PaneBarCustomizeSheetTests {

    /// Renders the sheet against an injected defaults domain.
    ///
    /// Without this the sheet's `@AppStorage` reads `UserDefaults.standard` — i.e. **the arrangement
    /// on the machine running the tests**. A developer who had customized their own bar would render
    /// a different sheet from CI's, and the height assertion below would be a coin flip on their
    /// machine. Same reason `DashboardSnapshotTests` injects the preview setting.
    private func laidOut(_ view: some View) -> CGSize {
        let defaults = ScratchDefaults("PaneBarCustomizeSheetTests-layout")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        let host = NSHostingView(rootView: AnyView(view.defaultAppStorage(defaults)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func testItemsTheEditingPaneCannotDrawAreStillOfferedButMarked() {
        // Collapse Pane is in the DEFAULT arrangement and only the single-source rail draws it, so a Compare
        // pane's sheet necessarily shows a pill its own bar does not have. That is honest — the
        // arrangement is shared — but it has to be visibly explained rather than looking like a bug
        // in the sheet.
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
        // 600 is not a taste call: it was the window's own `minWidth` when this was chosen, so
        // anything wider was a sheet wider than the window it belongs to at the size a user could
        // actually drag theirs down to. The window floor is 810 now, which only widens the margin —
        // the number stays because the track's metrics were tightened around it.
        // (The `<= 600` restatement that sat here was noise — it cannot fail while the line above
        // passes. One assertion, and the reason for the number in prose beside it.)
        #expect(size.width == 600, "the sheet should hold its declared width, got \(size.width)")
        // Tall enough to be a real sheet, short enough not to run off a laptop screen.
        #expect(size.height > 300 && size.height < 760, "sheet height \(size.height) is out of range")
    }

    @Test func testEveryPaletteItemIsSomethingTheBarCanPlace() {
        // A tile for an item the bar cannot draw would be a dead affordance: you would drag it on and
        // nothing would appear.
        let palette = PaneBarCustomizeSheet.palette
        #expect(Set(palette).count == palette.count, "the palette repeats an item")
        for item in palette {
            #expect(PaneBarItem.allCases.contains(item))
        }
    }

    @Test func testThePaletteOffersEveryRemovableControl() {
        // The other direction, and the one that rots: add a control to the bar, forget the tile, and
        // anyone who removes it can never put it back.
        for item in PaneBarItem.allCases where !item.isSpacer {
            #expect(PaneBarCustomizeSheet.palette.contains(item),
                    "\(item.displayName) can be on the bar but has no palette tile")
        }
    }

    @Test func testEveryPaletteGlyphIsARealSFSymbol() {
        // A typo'd symbol name doesn't fail anywhere — it draws nothing, and the tile becomes a
        // labelled blank. `PaneGlyphTests` pins the pane's other glyphs for exactly this reason.
        for item in PaneBarItem.allCases {
            #expect(NSImage(systemSymbolName: item.paletteSymbol, accessibilityDescription: nil) != nil,
                    "\(item.displayName) names a symbol that does not exist: \(item.paletteSymbol)")
        }
    }

    @Test func testScanIsOfferedButInert() {
        // Present so its absence from the removable set is explained, rather than leaving someone
        // hunting for a control that was never offered.
        #expect(PaneBarCustomizeSheet.palette.contains(.scan))
        #expect(!PaneBarItem.scan.isRemovable)
    }

    // MARK: Can you actually aim at it

    /// Right-clicks the centre of one track pill and reports the menu that came back, if any.
    ///
    /// This is the one interaction in this sheet a test *can* drive. The header note above is still
    /// right that the drags need a live event loop — but a context menu does not: SwiftUI answers
    /// `NSView.menu(for:)` on the hosting view, and it answers it by hit-testing the point. So the
    /// menu is a direct readout of whether the pill is aimable, which is the thing that was broken.
    /// A pill drawn as an unfilled outline is hit-testable only along the outline itself.
    private func menuAtCentre(of item: PaneBarItem) -> NSMenu? {
        let defaults = ScratchDefaults("PaneBarCustomizeSheetTests-aim")
        defaults.set(PaneBarArrangement([.space, .scan, .flexibleSpace, .sort]).encoded,
                     forKey: PaneBar.arrangementKey)
        let sheet = PaneBarCustomizeSheet()
        let host = NSHostingView(rootView: AnyView(sheet.trackItem(item, at: 0)
                                                       .defaultAppStorage(defaults)))
        // Borderless, and never ordered in. A `.titled` window cannot be parked off screen —
        // `constrainFrameRect` drags it back onto his desktop, over whatever he is doing.
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

    @Test func theSpaceOnTheTrackCanBeAimedAt() {
        // The bug this is here for: a fixed space could be added to the bar and never taken off.
        // Its pill is a dashed outline around an empty fill, so the drag, the drop and the context
        // menu were all attached to a 1pt ring, and every click in the middle of it went through to
        // the track behind. Nothing else in the sheet reaches a space — it has no palette check to
        // click off, and Restore is all-or-nothing.
        //
        // Both spacers, because only one of them was broken and the difference was an accident of
        // fill opacity, not a decision anyone made.
        for spacer in [PaneBarItem.space, .flexibleSpace] {
            let titles = menuAtCentre(of: spacer)?.items.map(\.title) ?? []
            #expect(titles.contains("Remove"),
                    "right-clicking the centre of \(spacer.displayName) offered \(titles); with no Remove there is no way to take it off the bar")
        }
    }

    @Test func soCanAControl() {
        // The control pills were never broken — they are drawn on a filled capsule. Here so that a
        // failure above is read as "the space is unaimable" rather than "the probe measures nothing",
        // which is the failure mode that would let the test pass while proving nothing.
        let titles = menuAtCentre(of: .sort)?.items.map(\.title) ?? []
        #expect(titles.contains("Remove"), "a control pill offered \(titles)")
    }

    /// **Every edit this sheet makes goes through `commit`**, which is what logs it.
    ///
    /// A source scan, because the alternative cannot be built: the five gestures that change the
    /// bar are a `Button` action, three drop handlers and an accessibility action, none of which a
    /// unit test can drive — a `Button` is not an `NSControl`. So a logging call added to four of
    /// the five sites would look exactly like one added to all five. What *is* checkable is an
    /// absence, and this is that: one write of the stored arrangement in the whole product, inside
    /// `commit`. A sixth gesture that writes it directly fails this test rather than silently going
    /// unlogged.
    ///
    /// **Scanned by the KEY, across every source file, not by the local variable's name.** The first
    /// version counted `"arrangementRaw = "` in this one file, and a write is not obliged to spell
    /// that: `UserDefaults.standard.set(next.encoded, forKey: PaneBar.arrangementKey)` inside
    /// `drop(_:at:)` is a live, unlogged sixth route that the count reported as absent, and
    /// `$arrangementRaw.wrappedValue =` evades it identically. One file was the wrong scope too —
    /// `DashboardViews.swift` holds the same `@AppStorage(PaneBar.arrangementKey)`, read-only today
    /// and with nothing saying it stays that way.
    @Test func testTheSheetWritesTheArrangementInExactlyOnePlace() throws {
        let writers = try Self.arrangementWrites()
        // Roots first. A scan whose file list or anchor came back empty measures nothing, and would
        // report "no stray writes" for free.
        #expect(Self.productionSources.count > 1,
                "the repo-wide scan found \(Self.productionSources.count) source files")
        #expect(Self.productionSources.contains { $0.lastPathComponent == "PaneBarCustomizeSheet.swift" },
                "the customize sheet is not in the scanned set, so its own writes are invisible here")
        #expect(Self.productionSources.contains { $0.lastPathComponent == "DashboardViews.swift" },
                "DashboardViews holds the same @AppStorage key and is not in the scanned set")
        // The known member of the derived set: the sheet's own binding. If the declaration scan
        // stopped finding @AppStorage declarations, every assignment count below would be zero.
        let bound = Self.arrangementBindings.map { "\($0.0.lastPathComponent).\($0.1)" }
        let bindingsChanged = "the files binding @AppStorage(PaneBar.arrangementKey) changed: \(bound)"
        #expect(Self.arrangementBindings.map { $0.0.lastPathComponent }.sorted()
                == ["DashboardViews.swift", "PaneBarCustomizeSheet.swift"], "\(bindingsChanged)")

        let strayWrites = "\(writers.count) places write the stored pane-bar arrangement — "
            + "\(writers). Every edit must go through PaneBarCustomizeSheet.commit(_:), which is "
            + "the only thing that logs it; the migration's own write is the one exemption and is "
            + "listed in `exempt` with its reason."
        #expect(writers.count == 1, "\(strayWrites)")

        // …and that one is inside `commit`, not merely somewhere in the file. `commit` is the last
        // member of its MARK group, so the next `private var`/`func` bounds it.
        let sheet = try Self.source()
        let commitStart = try #require(sheet.range(of: "private func commit(_ next: PaneBarArrangement)"),
                                       "the funnel is gone or renamed; this scan is vacuous without it")
        let tail = sheet[commitStart.upperBound...]
        let bodyEnd = tail.range(of: "\n    }")?.upperBound ?? tail.endIndex
        let body = tail[..<bodyEnd]
        #expect(body.contains("arrangementRaw = next.encoded"),
                "the single arrangement write is not inside commit(_:)")
        // **And that write is logged.** Deleting this one line left the whole suite green and
        // `PaneBarEditLog` dead code with nothing referencing it — the sheet's headline claim
        // ("all five gestures funnel through one commit, which is what logs it") rested on nothing.
        // The assignment being alone in `commit` is checked above; this is the other half.
        let unlogged = "commit(_:) writes the arrangement without logging it, so every gesture in "
            + "this sheet is silent and PaneBarEditLog has no caller at all"
        #expect(body.contains("PaneBarEditLog.record(from: before, to: next)"), "\(unlogged)")
    }

    /// Every write of the stored pane-bar arrangement in the product, as `file.member` strings.
    ///
    /// Two shapes, because a write has two spellings and only one of them mentions a variable this
    /// file could guess at:
    ///
    /// * an assignment to a property bound with `@AppStorage(PaneBar.arrangementKey)`, in whichever
    ///   file declares it, including through `$binding.wrappedValue`;
    /// * a `set(…, forKey:)` naming the key or its literal, anywhere.
    ///
    /// `PaneBarArrangement.swift` is exempt from the second: `PaneBarMigration.apply` writes the
    /// migrated bar there, before any `@AppStorage` wrapper has read it, and it is not a user edit
    /// to log — it has its own launch line. Exempted by its exact text AND its file, so a second
    /// write added to that file later is reported rather than quietly covered.
    ///
    /// **What it still cannot see**, stated rather than implied: a write whose key arrives through a
    /// local (`let k = PaneBar.arrangementKey; d.set(x, forKey: k)`), or through
    /// `setPersistentDomain`. Both are reachable and neither is a spelling anything in this repo
    /// uses; the two the review actually demonstrated — a direct `set(…, forKey:)` and
    /// `$binding.wrappedValue =` — are covered, and each is proven by mutation.
    private static func arrangementWrites() throws -> [String] {
        /// The migration's own write, quoted exactly. Exempt by its whole text and its file, so a
        /// SECOND write added to `PaneBarArrangement.swift` is reported rather than covered.
        let exempt = ("PaneBarArrangement.swift",
                      "defaults.set(arrangement.encoded, forKey: PaneBar.arrangementKey)")
        var writes: [String] = []
        for url in productionSources {
            let bindings = arrangementBindings.filter { $0.0 == url }.map(\.1)
            for line in try readStrippingComments(url).split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                // `hasSuffix` as well as `contains`, so an assignment whose value sits on the next
                // line — which is how the declarations in both these files are written — is not a
                // spelling the scan is blind to.
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

    /// Every Swift file the shipped app is built from — `Modules/*/Sources` plus `MacApp`.
    ///
    /// Repo-wide rather than this module's, because the key is `public` and nothing stops another
    /// module writing it. Tests are excluded deliberately: they set the key constantly, on scratch
    /// domains, which is the point of them.
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

    /// Source with whole-line comments removed — the prose in these files quotes the very spellings
    /// being counted, and a scan that read comments would answer its own question.
    private static func readStrippingComments(_ url: URL) throws -> String {
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read \(url.lastPathComponent) — this scan would be vacuous")
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)                 // …/Tests/Dashboard/<this>.swift
            .deletingLastPathComponent()                          // …/Tests/Dashboard
            .deletingLastPathComponent()                          // …/Tests
            .deletingLastPathComponent()                          // …/Dashboard
            .appendingPathComponent("Sources/Dashboard/PaneBarCustomizeSheet.swift")
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read PaneBarCustomizeSheet.swift — this scan would be vacuous")
    }
}
