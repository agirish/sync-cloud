import AppKit
import Design
import SwiftUI
import Sync
import Testing
@testable import FileExplorer
import FileExplorerTestSupport

/// The differences header's ladder, whose rung is computed rather than searched.
///
/// `HeaderLadder` chooses the rung by arithmetic instead of handing six candidate toolbars to
/// `ViewThatFits`, so the claim is that its numbers describe the row actually drawn. Checked two
/// ways, neither comparing a constant against another constant:
///
/// - Per rung: the width `HeaderLadder` computes is the width the row laid out at that rung
///   occupies (`NSHostingView.fittingSize`).
/// - End to end: at every width across a sweep, the row the computed rung produces is
///   pixel-identical to the row a six-child `ViewThatFits` chooses. That searched ladder is rebuilt
///   here, not kept in production, making a before/after oracle in one process (the same trick
///   `PaneBarLadderTests` uses).
///
/// Controls are located by `_FocusRingView`, the handle `PaneBarLadderTests` reaches for: a SwiftUI
/// `Button` with a custom style draws into a layer and puts no `NSControl` in the AppKit tree, and
/// an offscreen `NSHostingView` has an empty accessibility tree.
///
/// Every hosting view here gets a real window: a detached `NSHostingView` mis-measures SF Symbols
/// in both directions, so a suite without one would fail against correct numbers.
/// `.oneMountedDifferencesTable`, though nothing here mounts a whole `DifferencesView`, because
/// this suite hosts more views than any other in the target, and that trait stops the priciest
/// main-actor work stacking up and starving the deadlines the mounting suites wait on.
/// `.machinePinned(.pixelSampling)` for `PaneBarLadderTests`' reason: every assertion reads
/// laid-out geometry back out of a live renderer, so another Mac fails it for machine reasons.
@MainActor
@Suite(.serialized, .oneMountedDifferencesTable, .machinePinned(.pixelSampling))
struct HeaderLadderTests {

    // MARK: - Fixtures

    /// A comparison whose header has something in every slot: both directions non-empty, verifiable
    /// items for Verify, and enough folders to offer the fold-all toggle.
    private func differences(toRight: Int = 12, toLeft: Int = 5, verifiable: Int = 4, held: Int = 0,
                             folders: [String] = ["Documents", "Photos", "Projects"]) -> [FileDifference] {
        var rows: [FileDifference] = []
        // Held rows (`heldBack`): no transfer button counts them, and the header says how many.
        for index in 0..<held {
            rows.append(FileDifference(
                relativePath: "\(folders[index % folders.count])/held-\(index).txt",
                leftItemPath: "/left/held-\(index).txt", rightItemPath: "/right/held-\(index).txt",
                type: .differentDates, action: .copyToRight,
                description: "Sizes differ but the dates are the same — choose which to keep",
                leftFileSize: 10, rightFileSize: 20, heldBack: .sizesDifferWithoutANewerSide))
        }
        for index in 0..<toRight {
            rows.append(FileDifference(
                relativePath: "\(folders[index % folders.count])/right-\(index).txt",
                leftItemPath: "/left/right-\(index).txt", rightItemPath: "/right/right-\(index).txt",
                type: .missingOnRight, action: .copyToRight,
                description: "Only on the left", leftFileSize: 1024))
        }
        for index in 0..<toLeft {
            rows.append(FileDifference(
                relativePath: "\(folders[index % folders.count])/left-\(index).txt",
                leftItemPath: "/left/left-\(index).txt", rightItemPath: "/right/left-\(index).txt",
                type: .missingOnLeft, action: .copyToLeft,
                description: "Only on the right", rightFileSize: 2048))
        }
        for index in 0..<verifiable {
            rows.append(FileDifference(
                relativePath: "\(folders[index % folders.count])/dates-\(index).txt",
                leftItemPath: "/left/dates-\(index).txt", rightItemPath: "/right/dates-\(index).txt",
                type: .differentDates, action: .copyToRight,
                description: "Different dates", leftFileSize: 4096, rightFileSize: 4096))
        }
        return rows
    }

    /// The dressings the count pill can wear. Each changes the pill's width, so the ladder has to
    /// price all three: no scan yet, a fresh age run, and a stale one, which wears an inset capsule
    /// worth `2 × 6pt` more than the bare run.
    private static func dressings() -> [(name: String, value: DifferencesView.CountPillDressing)] {
        let accent = SemanticCapsuleStyle.onAccent(fill: .blue, label: .white)
        return [
            ("pre-scan", .init(semantic: accent, detailStyle: nil, detail: nil,
                               spokenDetail: nil, help: nil)),
            ("fresh", .init(semantic: accent, detailStyle: nil, detail: "29m ago",
                            spokenDetail: "29m ago", help: "Last scanned 10:15:00")),
            ("stale", .init(semantic: accent, detailStyle: .of(.attention, .light), detail: "3h ago",
                            spokenDetail: "3h ago", help: "This comparison may be out of date")),
            ("scanning", .init(semantic: accent, detailStyle: .of(.neutral, .light),
                               detail: "scanning…", spokenDetail: "scanning for changes",
                               help: "Scanning for changes…")),
        ]
    }

    /// Pane names of very different lengths: the transfer buttons' destinations, and so the biggest
    /// lever on where the rungs sit.
    private static let paneNamePairs: [(String, String)] = [
        ("Left", "Right"),
        ("iCloud Drive", "Dropbox"),
        ("OneDrive — Personal", "Google Drive — someone@example.com"),
    ]

    /// A view whose state is the header's defaults. `@State` reads its initial value when the row
    /// is hosted without its owning view, which is the snapshot `facts(...)` below describes.
    private func view(rows: [FileDifference],
                      names: PaneProviderNames,
                      hasScanned: Bool = true) -> DifferencesView {
        let manager = FileSyncManager()
        manager.differences = rows
        manager.hasScanned = hasScanned
        manager.leftItemCount = 1_284
        manager.rightItemCount = 976
        return DifferencesView(syncManager: manager, reviewStore: ReviewSessionStore(),
                               paneNames: names, isCollapsed: .constant(false))
    }

    /// The facts the row about to be rendered really has, built from the values the row draws with
    /// rather than by hand, so a fixture can't describe a header the test isn't rendering.
    private func facts(rows: [FileDifference], names: PaneProviderNames,
                       dressing: DifferencesView.CountPillDressing,
                       targets: DifferenceActionTargets,
                       sections: [DifferenceGrouping.Section],
                       itemCounts: String? = nil,
                       hasScanned: Bool = true) -> HeaderLadder.Facts {
        HeaderLadder.Facts(
            differencesCount: rows.count,
            detail: dressing.detail,
            detailIsCapsuled: dressing.detailStyle != nil,
            chevronSymbol: CountPillChevron.symbol(hasScanned: hasScanned, expanded: false),
            itemCountsText: itemCounts,
            sectionCount: sections.count,
            filterName: DifferenceFilter.all.displayName(leftName: names.left, rightName: names.right),
            isSelectionScoped: targets.isSelectionScoped,
            targetCount: targets.targets.count,
            verifiableCount: targets.verifiableCount,
            copyToLeftCount: targets.copyToLeftCount,
            copyToRightCount: targets.copyToRightCount,
            heldText: targets.heldText,
            reverseIsMajority: targets.dominantCopyDirection == .copyToLeft,
            leftName: names.left, rightName: names.right,
            isMove: false,
            showsCollapseToggle: true)
    }

    // MARK: - Rendering

    /// Hosts `view` under the header card's own chrome, in a real window, at `width` if given.
    private func host<V: View>(_ view: V, width: CGFloat? = nil) -> NSHostingView<AnyView> {
        var root = AnyView(view.modifier(HeaderCardChrome()))
        if let width { root = AnyView(root.frame(width: width)) }
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: width ?? 4_000, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Every `_FocusRingView` in the laid-out row, as a stable string. This is the "what got drawn"
    /// signal: two rows with the same fingerprint drew the same controls in the same places.
    private func fingerprint(_ host: NSView) -> String {
        let found = FocusRings.frames(in: host)
        return found
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
            .map { "\(Int($0.minX.rounded())),\(Int($0.minY.rounded()))/"
                 + "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
            .joined(separator: " ")
    }

    // MARK: - The arithmetic against the drawn row

    /// The claim the computed ladder rests on: the width `HeaderLadder` computes for a rung is the
    /// width the row drawn at that rung occupies. Swept over every rung, count-pill dressing and
    /// pane-name pair, because those fixtures vary exactly the widths that move the rungs.
    @Test func everyRungMeasuresWhatItDraws() {
        var failures: [String] = []
        var checked = 0
        for (leftName, rightName) in Self.paneNamePairs {
            let names = PaneProviderNames(leftName: leftName, rightName: rightName)
            let rows = differences()
            let view = view(rows: rows, names: names)
            let targets = DifferenceActionTargets(filtered: rows, selection: [])
            let sections = DifferenceGrouping.sections(rows)
            for (dressingName, dressing) in Self.dressings() {
                let ladder = HeaderLadder(
                    facts: facts(rows: rows, names: names, dressing: dressing,
                                 targets: targets, sections: sections),
                    scale: 1)
                for rung in DifferencesView.renderedCompactionLadder {
                    let drawn = host(view.standardHeaderRow(rung, facts: ladder.facts,
                                                            dressing: dressing,
                                                            targets: targets, sorted: rows,
                                                            sections: sections)).fittingSize.width
                    checked += 1
                    if ladder.width(of: rung) != drawn {
                        failures.append("\(leftName)/\(rightName) \(dressingName) \(rung): "
                                        + "computed \(ladder.width(of: rung))pt, drew \(drawn)pt")
                    }

                }
            }
        }
        #expect(checked == Self.paneNamePairs.count * Self.dressings().count
                * DifferencesView.renderedCompactionLadder.count)
        let report = failures.joined(separator: "\n")
        #expect(failures.isEmpty, "\(failures.count) rung(s) mispriced:\n\(report)")
    }

    /// The same claim at the other three font scales. Split from the case above so a failure names
    /// the scale rather than being buried in a 96-case sweep.
    @Test(arguments: [FontSize.small, .large, .extraLarge])
    func everyRungMeasuresWhatItDrawsAtOtherFontScales(size: FontSize) {
        let scale = size.scale
        let names = PaneProviderNames(leftName: "iCloud Drive", rightName: "Dropbox")
        let rows = differences()
        let view = view(rows: rows, names: names)
        let targets = DifferenceActionTargets(filtered: rows, selection: [])
        let sections = DifferenceGrouping.sections(rows)
        var failures: [String] = []
        for (dressingName, dressing) in Self.dressings() {
            let ladder = HeaderLadder(facts: facts(rows: rows, names: names, dressing: dressing,
                                                   targets: targets, sections: sections),
                                      scale: scale)
            for rung in DifferencesView.renderedCompactionLadder {
                let row = view.standardHeaderRow(rung, facts: ladder.facts, dressing: dressing,
                                                 targets: targets, sorted: rows, sections: sections)
                let drawn = host(row.appFontSize(size)).fittingSize.width
                if ladder.width(of: rung) != drawn {
                    failures.append("\(dressingName) \(rung): computed \(ladder.width(of: rung))pt, "
                                    + "drew \(drawn)pt")
                }
            }
        }
        let report = failures.joined(separator: "\n")
        #expect(failures.isEmpty, "at scale \(scale), \(failures.count) rung(s) mispriced:\n\(report)")
    }

    /// Two runs the everyday fixture is too small to exercise:
    ///
    /// - A four-figure count. The Review button interpolates its count plainly (`Review 1284`)
    ///   while the count pill beside it formats (`1,284`). Pricing Review with `.formatted()` looks
    ///   right and is 4pt too wide, invisible below a thousand targets and routine on a real
    ///   comparison.
    /// - The expanded per-side totals, the one run whose text comes from view state rather than the
    ///   data, so it is measurable only because the row is handed the `facts` the ladder priced.
    @Test func aLargeComparisonWithTheTotalsExpandedIsPricedExactly() {
        let names = PaneProviderNames(leftName: "OneDrive — Personal", rightName: "iCloud Drive")
        let rows = differences(toRight: 1_284, toLeft: 976, verifiable: 431)
        let view = view(rows: rows, names: names)
        let targets = DifferenceActionTargets(filtered: rows, selection: [])
        let sections = DifferenceGrouping.sections(rows)
        #expect(targets.targets.count > 999, "the fixture has to cross the thousands separator")

        for (dressingName, dressing) in Self.dressings() {
            for totals in [nil, "1,284 OneDrive — Personal · 976 iCloud Drive"] as [String?] {
                let ladder = HeaderLadder(
                    facts: facts(rows: rows, names: names, dressing: dressing, targets: targets,
                                 sections: sections, itemCounts: totals),
                    scale: 1)
                for rung in DifferencesView.renderedCompactionLadder {
                    let drawn = host(view.standardHeaderRow(rung, facts: ladder.facts,
                                                            dressing: dressing, targets: targets,
                                                            sorted: rows, sections: sections))
                        .fittingSize.width
                    let note = "\(dressingName) \(rung) totals=\(totals != nil): "
                        + "computed \(ladder.width(of: rung))pt, drew \(drawn)pt"
                    #expect(ladder.width(of: rung) == drawn, "\(note)")
                }
            }
        }
    }

    /// The states every other case here leaves at their defaults, each a whole control or label
    /// vocabulary nothing else measures: a selection chip (`isSelectionScoped`), the Move labels
    /// (`isMove`, true only while ⇧/⌘ is held), the pre-scan pill (no chevron), an empty
    /// comparison, an ungrouped table (no fold-all toggle), and a host binding no collapse state.
    ///
    /// Swept as a matrix, because the interesting failures are interactions, such as a selection
    /// chip present alongside a folded overflow.
    @Test func everyHeaderStateIsPricedExactly() {
        let names = PaneProviderNames(leftName: "OneDrive — Personal", rightName: "iCloud Drive")
        var failures: [String] = []
        var checked = 0

        // (label, rows, scope the selection?, ⇧ held?, group into sections?, bind collapse?, scanned?)
        let states: [(String, [FileDifference], Bool, Bool, Bool, Bool, Bool)] = [
            ("selection-scoped",     differences(),                                true,  false, true,  true,  true),
            ("move modifier",        differences(),                                false, true,  true,  true,  true),
            ("scoped + move",        differences(),                                true,  true,  true,  true,  true),
            ("nothing to sync",      [],                                           false, false, false, true,  true),
            ("one-way only",         differences(toRight: 9, toLeft: 0, verifiable: 0), false, false, true,  true,  true),
            ("reverse-only",         differences(toRight: 0, toLeft: 9, verifiable: 0), false, false, true,  true,  true),
            ("reverse is majority",  differences(toRight: 2, toLeft: 40, verifiable: 0), false, false, true,  true,  true),
            ("nothing verifiable",   differences(toRight: 6, toLeft: 3, verifiable: 0), false, false, true,  true,  true),
            ("ungrouped (no folds)", differences(),                                false, false, false, true,  true),
            ("no collapse binding",  differences(),                                false, false, true,  false, true),
            ("pre-scan",             differences(),                                false, false, true,  true,  false),
            ("some held",            differences(held: 2),                         false, false, true,  true,  true),
            ("all held",             differences(toRight: 0, toLeft: 0, verifiable: 0, held: 3), false, false, true,  true,  true),
        ]

        for (label, rows, scoped, isMove, grouped, binds, scanned) in states {
            let manager = FileSyncManager()
            manager.differences = rows
            manager.hasScanned = scanned
            let view = DifferencesView(syncManager: manager, reviewStore: ReviewSessionStore(),
                                       paneNames: names,
                                       isCollapsed: binds ? .constant(false) : nil)
            // A real selection, resolved against the visible rows as the header resolves it:
            // `DifferenceActionTargets` falls back to the whole filtered set if the ids miss, which
            // would silently un-scope the fixture.
            let selection = scoped ? Set(rows.prefix(3).map(\.id)) : Set<FileDifference.ID>()
            let targets = DifferenceActionTargets(filtered: rows, selection: selection)
            #expect(targets.isSelectionScoped == scoped,
                    "\(label): fixture failed to scope the selection — the case would be vacuous")
            let sections = grouped ? DifferenceGrouping.sections(rows) : []

            for (dressingName, dressing) in Self.dressings() {
                var f = facts(rows: rows, names: names, dressing: dressing, targets: targets,
                              sections: sections, hasScanned: scanned)
                f.isMove = isMove
                f.showsCollapseToggle = binds
                let ladder = HeaderLadder(facts: f, scale: 1)
                for rung in DifferencesView.renderedCompactionLadder {
                    let drawn = host(view.standardHeaderRow(rung, facts: f, dressing: dressing,
                                                            targets: targets, sorted: rows,
                                                            sections: sections)).fittingSize
                    checked += 1
                    if ladder.width(of: rung) != drawn.width {
                        failures.append("\(label)/\(dressingName)/\(rung): "
                                        + "computed \(ladder.width(of: rung))pt, drew \(drawn.width)pt")
                    }
                    if drawn.height != ActionBarMetrics.height {
                        failures.append("\(label)/\(dressingName)/\(rung): row is \(drawn.height)pt "
                                        + "tall, but the header pins it to \(ActionBarMetrics.height)pt")
                    }
                }
            }
        }
        let report = failures.joined(separator: "\n")
        #expect(checked == states.count * Self.dressings().count
                * DifferencesView.renderedCompactionLadder.count)
        #expect(failures.isEmpty, "\(failures.count) of \(checked) mispriced:\n\(report)")
    }

    /// The height the `GeometryReader` is pinned to. The filter menu is an action-bar capsule on
    /// the row at every rung, so it sets the row's height whatever else is shed, including at the
    /// largest font scale, where the capsule keeps its 28pt frame while its label grows inside it.
    @Test func theRowIsAlwaysTheActionBarHeight() {
        let names = PaneProviderNames(leftName: "iCloud Drive", rightName: "Dropbox")
        let rows = differences()
        let view = view(rows: rows, names: names)
        let targets = DifferenceActionTargets(filtered: rows, selection: [])
        let sections = DifferenceGrouping.sections(rows)
        for size in FontSize.allCases {
            for (dressingName, dressing) in Self.dressings() {
                for rung in DifferencesView.renderedCompactionLadder {
                    let ladder = HeaderLadder(facts: facts(rows: rows, names: names,
                                                           dressing: dressing, targets: targets,
                                                           sections: sections),
                                              scale: size.scale)
                    let row = view.standardHeaderRow(rung, facts: ladder.facts, dressing: dressing,
                                                     targets: targets, sorted: rows, sections: sections)
                    let drawn = host(row.appFontSize(size)).fittingSize.height
                    let message = "\(dressingName) \(rung) at \(size) drew \(drawn)pt tall, but "
                        + "the header pins the row to \(ActionBarMetrics.height)pt"
                    #expect(drawn == ActionBarMetrics.height, "\(message)")
                }
            }
        }
    }

    // MARK: - The computed rung against the searched one

    /// The end-to-end oracle: across a width sweep, the row the arithmetic picks is the row a
    /// six-child `ViewThatFits` picks: same controls, same places, to the point. The searched
    /// ladder is rebuilt here (`searchedLadder`), so this isn't the new code checking itself.
    @Test func theComputedRungDrawsWhatTheSearchedLadderDrew() {
        // `searchedLadder` spells its six rungs out because `ViewThatFits` can't take a loop. If a
        // rung is added, this fails rather than quietly comparing against a ladder one rung short.
        #expect(DifferencesView.renderedCompactionLadder.count == 6,
                "the ladder has changed length — update `searchedLadder` to match before trusting it")
        var disagreements: [String] = []
        var compared = 0
        for (leftName, rightName) in Self.paneNamePairs {
            let names = PaneProviderNames(leftName: leftName, rightName: rightName)
            let rows = differences()
            let view = view(rows: rows, names: names)
            let targets = DifferenceActionTargets(filtered: rows, selection: [])
            let sections = DifferenceGrouping.sections(rows)
            let (_, dressing) = Self.dressings()[1]     // the everyday case: a fresh age run
            let ladder = HeaderLadder(facts: facts(rows: rows, names: names, dressing: dressing,
                                                   targets: targets, sections: sections),
                                      scale: 1)
            for width in Self.oracleWidths(ladder) {
                let searched = fingerprint(host(searchedLadder(view, facts: ladder.facts,
                                                              dressing: dressing, targets: targets,
                                                              sorted: rows, sections: sections),
                                                width: width))
                let computed = fingerprint(host(
                    view.standardHeaderRow(ladder.rung(fitting: width), facts: ladder.facts,
                                           dressing: dressing, targets: targets, sorted: rows,
                                           sections: sections),
                    width: width))
                compared += 1
                if searched != computed {
                    disagreements.append("\(leftName)/\(rightName) at \(width)pt "
                                         + "→ computed \(ladder.rung(fitting: width))\n"
                                         + "  searched: \(searched)\n  computed: \(computed)")
                }
            }
        }
        #expect(compared > 150, "the sweep collapsed to \(compared) widths — it proves nothing")
        let report = disagreements.prefix(5).joined(separator: "\n")
        #expect(disagreements.isEmpty,
                "\(disagreements.count) of \(compared) widths disagree:\n\(report)")
    }

    /// The widths the oracle compares at.
    ///
    /// Concentrated at the rung boundaries, the only place the two methods can disagree: between
    /// them both hold the same rung for tens of points. Half-point steps either side of each
    /// boundary, SwiftUI's own layout granularity, so a half-point arithmetic error is caught where
    /// a uniform 4pt sweep would step over it. A coarse pass over the whole range catches anything
    /// not boundary-shaped.
    private static func oracleWidths(_ ladder: HeaderLadder) -> [CGFloat] {
        var widths = Set<CGFloat>()
        for rung in DifferencesView.renderedCompactionLadder {
            let boundary = ladder.width(of: rung)
            for delta in stride(from: CGFloat(-2), through: 2, by: 0.5) { widths.insert(boundary + delta) }
        }
        for width in stride(from: CGFloat(340), through: 1_500, by: 80) { widths.insert(width) }
        // Below the narrowest rung, where nothing fits. The header's `minWidth` must reserve what
        // `ViewThatFits` advertises as its minimum (its last child's width), or the card can be
        // squeezed narrower than the row.
        for width in [CGFloat(120), 200, 260, 300] { widths.insert(width) }
        return widths.sorted()
    }

    /// The header's ladder searched the `ViewThatFits` way: six rows, widest first. The oracle
    /// above compares against this.
    @ViewBuilder
    private func searchedLadder(_ view: DifferencesView,
                                facts: HeaderLadder.Facts,
                                dressing: DifferencesView.CountPillDressing,
                                targets: DifferenceActionTargets,
                                sorted: [FileDifference],
                                sections: [DifferenceGrouping.Section]) -> some View {
        func row(_ rung: HeaderCompaction) -> some View {
            view.standardHeaderRow(rung, facts: facts, dressing: dressing, targets: targets,
                                   sorted: sorted, sections: sections)
        }
        // Six literals, not a `ForEach`: `ViewThatFits` counts a `ForEach` as a single child, and
        // the ladder would collapse to one rung. That makes this the one hand-written mirror of
        // `renderedCompactionLadder` (the view itself reads that array), so the oracle asserts the
        // count before trusting it.
        return ViewThatFits(in: .horizontal) {
            row(.full)
            row(.foldVerify)
            row(.foldReview)
            row(.shortReverse)
            row(.glyphFilter)
            row(.shortPrimary)
        }
    }

    // MARK: - The mounted view

    /// Mounts the real `DifferencesView` and checks that the header on screen is a rung of this
    /// ladder, and that it sheds as the window narrows.
    ///
    /// The cases above measure `standardHeaderRow` in isolation, leaving the join untested: the
    /// rung is chosen from a `GeometryReader`'s width inside the header card, and if that width
    /// isn't the width the row is offered, every rung boundary moves. The assertion doesn't
    /// hard-code the card's inner width; it asks whether one inset explains every observation
    /// through the ladder.
    ///
    /// Two limits:
    ///
    /// - "It got narrower" is not enough. With `rung(fitting:)` broken to always answer `.full`,
    ///   the row still sheds, because the hedge's `ViewThatFits` drops it to the terminal rung.
    ///   Only a working ladder produces the middle rungs, so those are asserted explicitly.
    /// - A uniform error in every rung's width is invisible here, because the inset search absorbs
    ///   it. `everyRungMeasuresWhatItDraws`, comparing absolute widths, catches that class.
    @Test func theMountedHeaderDrawsARungAndShedsAsThePaneNarrows() async {
        let names = PaneProviderNames(leftName: "OneDrive — Personal", rightName: "iCloud Drive")
        let rows = differences()
        let manager = FileSyncManager()
        manager.differences = rows
        manager.hasScanned = true
        let targets = DifferenceActionTargets(filtered: rows, selection: [])
        let sections = DifferenceGrouping.sections(rows)
        // `lastScanDate` is nil on this fixture, so `withScanFreshness` takes its else branch and
        // the pill wears the pre-scan dressing, the one the isolated rows below are built with.
        let dressing = Self.dressings()[0].value
        let probe = view(rows: rows, names: names)

        /// The ring sizes of one rung drawn in isolation. Sizes, not positions: the mounted row
        /// sits inside the card's padding, so its coordinates are shifted, but which controls are
        /// on it and how wide each is tells the rungs apart.
        func sizes(ofRung rung: HeaderCompaction, width: CGFloat) -> [String] {
            ringSizes(host(probe.standardHeaderRow(rung, facts: facts(rows: rows, names: names,
                                                                      dressing: dressing,
                                                                      targets: targets,
                                                                      sections: sections),
                                                   dressing: dressing, targets: targets,
                                                   sorted: rows, sections: sections),
                           width: width))
        }

        var matched: [(CGFloat, Int)] = []
        for paneWidth in [CGFloat(1_500), 1_100, 820, 620, 480] {
            let mount = mountDifferences(rows: rows, names: names, width: paneWidth)
            defer { mount.window.contentView = nil }
            // Grouping is on, so the table draws a header row per section as well as the rows.
            let expectedRows = rows.count + sections.count
            let settled = await settle(mount.host, atRows: expectedRows)
            let settleNote = "table settled at \(settled.rows) row(s) after \(settled.pumps) passes, "
                + "not \(expectedRows) — the header would be measured half-built and every "
                + "assertion below would be vacuous"
            #expect(settled.rows == expectedRows, "\(settleNote)")
            let drawn = headerRingSizes(mount.host)
            #expect(!drawn.isEmpty, "no header controls found at \(paneWidth)pt")

            // Which rung is this? Compare against each rung drawn at the same pane width; only the
            // control widths matter, and those do not depend on the leading offset.
            let rungIndex = DifferencesView.renderedCompactionLadder.firstIndex {
                sizes(ofRung: $0, width: paneWidth) == drawn
            }
            #expect(rungIndex != nil,
                    "the mounted header at \(paneWidth)pt matches no rung of the ladder — drew \(drawn)")
            if let rungIndex { matched.append((paneWidth, rungIndex)) }
        }

        let trace = matched.map { "\(Int($0.0))pt→rung\($0.1)" }.joined(separator: " ")
        #expect(matched.count == 5, "only \(matched.count) pane width(s) matched a rung — \(trace)")
        #expect(matched.first?.1 == 0, "a 1,500pt pane should draw the unshed row — \(trace)")
        for (a, b) in zip(matched, matched.dropFirst()) {
            #expect(b.1 >= a.1, "narrowing \(a.0)pt → \(b.0)pt moved the ladder back UP — \(trace)")
        }

        // The decisive check: with the arithmetic broken to always answer `.full`, the row still
        // sheds (the hedge's `ViewThatFits` drops it to the terminal rung), so "it got narrower"
        // passes over a ladder doing nothing. Only a working ladder produces the middle rungs.
        let ladder = HeaderLadder(facts: facts(rows: rows, names: names, dressing: dressing,
                                               targets: targets, sections: sections), scale: 1)
        let terminalIndex = DifferencesView.renderedCompactionLadder.count - 1
        let middleNote = "every pane landed on the widest or the narrowest rung, so the intermediate "
            + "rungs were never chosen by the arithmetic — \(trace)"
        #expect(matched.contains { $0.1 > 0 && $0.1 < terminalIndex }, "\(middleNote)")

        // And the plumbing: one card inset must explain every observation through this ladder. If
        // the `GeometryReader` were offered a different width from the row's, no single inset
        // would fit all five.
        let insets = stride(from: CGFloat(0), through: 200, by: 0.5).filter { inset in
            matched.allSatisfy { paneWidth, rungIndex in
                ladder.rung(fitting: paneWidth - inset)
                    == DifferencesView.renderedCompactionLadder[rungIndex]
            }
        }
        #expect(!insets.isEmpty,
                "no single card inset explains the rungs the mounted header drew — \(trace)")
    }

    /// Mounts the real view in a real (never ordered-in) window, the way the other mounting suites do.
    private func mountDifferences(rows: [FileDifference], names: PaneProviderNames,
                                  width: CGFloat) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let store = ScratchDefaults("HeaderLadderTests")
        store.set(true, forKey: "differencesGroupByFolder")
        let manager = FileSyncManager()
        manager.differences = rows
        manager.hasScanned = true
        let root = DifferencesView(syncManager: manager, reviewStore: ReviewSessionStore(),
                                   paneNames: names, isCollapsed: .constant(false))
            .defaultAppStorage(store)
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    /// Waits for the differences table to settle at exactly `expected` rows. The header's shape
    /// depends on `sections`, empty until the rows land, so measuring early reads a header the user
    /// never sees. Bounded by `LayoutPumpWait`'s pass floor as well as its deadline, and reports
    /// the passes so a failure says whether it was starved or disproved: the rows arrive on
    /// main-actor turns, which a congested run gets fewer of. See `docs/flaky-tests.md`, "Fixed
    /// pumps and fixed sleeps".
    private func settle(_ view: NSView, atRows expected: Int,
                        timeout: TimeInterval = 15) async -> (rows: Int, pumps: Int) {
        var last = 0
        let outcome = await LayoutPumpWait.pump(view, upTo: timeout) {
            last = tableRowCount(view) ?? 0
            return last == expected
        }
        return (last, outcome.pumps)
    }

    private func tableRowCount(_ view: NSView) -> Int? {
        if let table = view as? NSTableView { return table.numberOfRows }
        for child in view.subviews {
            if let rows = tableRowCount(child) { return rows }
        }
        return nil
    }

    /// Every `_FocusRingView` size in reading order, as `WxH` strings.
    private func ringSizes(_ host: NSView) -> [String] {
        let found = FocusRings.frames(in: host)
        return found.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
            .map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
    }

    /// The header strip's rings only: the top band of the mounted view, above the table.
    private func headerRingSizes(_ host: NSView) -> [String] {
        let found = FocusRings.frames(in: host)
        guard let top = found.map(\.minY).min() else { return [] }
        return found.filter { $0.minY < top + 10 }
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
            .map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
    }

    // MARK: - The rule the ladder follows

    /// `rung(fitting:)` mirrors `ViewThatFits`: the first rung that fits, in declaration order, and
    /// the narrowest when none does. Stated directly so the property survives a fixture change.
    @Test func theLadderTakesTheFirstRungThatFitsAndBottomsOut() {
        let names = PaneProviderNames(leftName: "iCloud Drive", rightName: "Dropbox")
        let rows = differences()
        let targets = DifferenceActionTargets(filtered: rows, selection: [])
        let sections = DifferenceGrouping.sections(rows)
        let ladder = HeaderLadder(facts: facts(rows: rows, names: names,
                                               dressing: Self.dressings()[1].value,
                                               targets: targets, sections: sections),
                                  scale: 1)

        #expect(ladder.rung(fitting: 10_000) == .full, "an unconstrained row should shed nothing")
        #expect(ladder.rung(fitting: 0) == ladder.terminal, "nothing fits at zero — bottom out")
        #expect(ladder.terminal == HeaderCompaction.shortPrimary)

        for width in stride(from: CGFloat(200), through: 1_600, by: 1) {
            let chosen = ladder.rung(fitting: width)
            let need = ladder.width(of: chosen)
            #expect(chosen == ladder.terminal || need <= width,
                    "chose \(chosen) at \(width)pt, which needs \(need)pt")
        // Nothing above the chosen rung may fit, or the search would have taken it first.
            for earlier in DifferencesView.renderedCompactionLadder where earlier < chosen {
                #expect(ladder.width(of: earlier) > width,
                        "\(earlier) fits at \(width)pt but \(chosen) was chosen")
            }
        }
    }

    /// This ladder is monotonically non-increasing, a measured fact about it, not a property of
    /// shedding ladders in general.
    ///
    /// In `PaneBarLadder`, dropping a control narrower than the ⋯ pill it gains can make the bar
    /// wider. Nothing here can: every rung sheds a run of text or is a no-op, and the widest thing
    /// any rung adds is the 28pt overflow in place of a Verify button never narrower than ~90pt. A
    /// rung added later that does widen the row shows up here rather than becoming unreachable.
    ///
    /// Ties are expected, and are why declaration order still matters: a rung whose concession
    /// doesn't apply (no reverse button to shorten, nothing verifiable to fold) costs nothing, and
    /// a tie must resolve to the earlier rung to match `ViewThatFits`.
    @Test func theLadderNeverWidensAsItSheds() {
        for (leftName, rightName) in Self.paneNamePairs {
            let names = PaneProviderNames(leftName: leftName, rightName: rightName)
            for rows in [differences(),
                         differences(toRight: 1, toLeft: 0, verifiable: 1, folders: ["Documents"]),
                         differences(toRight: 3, toLeft: 400, verifiable: 0),
                         differences(toRight: 0, toLeft: 9, verifiable: 2)] {
                let targets = DifferenceActionTargets(filtered: rows, selection: [])
                let sections = DifferenceGrouping.sections(rows)
                for (dressingName, dressing) in Self.dressings() {
                    let ladder = HeaderLadder(
                        facts: facts(rows: rows, names: names, dressing: dressing,
                                     targets: targets, sections: sections),
                        scale: 1)
                    let widths = DifferencesView.renderedCompactionLadder.map { ladder.width(of: $0) }
                    let report = "\(leftName)/\(rightName) \(dressingName) rows=\(rows.count): \(widths)"
                    #expect(widths == widths.sorted(by: >=), "a rung WIDENS the row — \(report)")
                }
            }
        }
    }
}
