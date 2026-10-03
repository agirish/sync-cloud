import Testing
import Foundation

/// Chrome glass's call sites in Dashboard (RD46 follow-up, 2026-10-03) beyond what
/// `ChromeGlassPaneBarTests` renders: the breadcrumb's source pill, the Activity Log and Sync
/// History headers, and the log's level chips. A site that loses its glass fails safe to the Solid
/// look, so only a scan sees it.
///
/// Read over `PaneBarInkChokePointTests.codeOnly`: these call sites carry comments that name the
/// very modifiers counted here, and a scan of the raw text passed with the code gone.
@Suite struct ChromeGlassWiringTests {

    static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Dashboard/\(file)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(file) — every scan here would be vacuous")
        try #require(text.count > 500, "\(file) read as \(text.count) characters — truncated?")
        return PaneBarInkChokePointTests.codeOnly(text)
    }

    static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test func theBreadcrumbsSourcePillWearsGlassUnderItsBrandWash() throws {
        let crumb = try Self.source("PaneBreadcrumb.swift")
        let wash = try #require(crumb.range(of: ".fill(hue?.tint.opacity(SourceChip.washOpacity) ?? .clear)"))
        // Gated on the wash's own optional: a crumb with no source stays the bare crumb it was. No
        // rim: the brand hairline is the pill's edge, and Clear's under it doubled it.
        let glass = try #require(crumb.range(of: ".chromeGlassGround(.capsule, rim: false, when: hue != nil)"),
                                 "the source pill lost its glass, or wears it with no source, or doubles its edge")
        // After the wash in the chain, so the glass is BEHIND it and the brand colour stays painted.
        #expect(glass.lowerBound > wash.upperBound)
    }

    @Test func theLogAndHistoryHeadersUseGlassButtons() throws {
        #expect(Self.count(".chromeGlassBorderedButtonStyle()", in: try Self.source("LogViewer.swift")) == 3,
                "Copy, Clear and Open log file")
        #expect(Self.count(".chromeGlassBorderedButtonStyle()", in: try Self.source("SyncHistoryView.swift")) == 3,
                "Undo Last Run, Export and Clear — one header, one kind of button")
    }

    /// The level chips are a pick-one row like every other that wears a lens; the row scrolls, so
    /// the host is handed what the scroll view shows — a move off either edge switches instantly.
    @Test func theLogsLevelChipsHostALens() throws {
        let log = try Self.source("LogViewer.swift")
        #expect(log.contains(".selectionLensHost(Self.levelLensChannel"))
        #expect(log.contains(".selectionLensStop(Self.levelLensChannel"))
        #expect(log.contains("visibleRegion: visibleLevels)"))
        #expect(log.contains(".selectionLensTracksVisibleRegion(visibleLevels)"))
        // The chosen chip's name and count: on-fill ink at Solid and on dark glass, `.primary` and `.secondary` on light.
        #expect(Self.count(".selectionLensLabelInk(isSelected: selected", in: log) == 2)
        #expect(log.contains("onGlass: .secondary, unselected: .secondary)"), "the count's glass ink")
    }

    /// The current row's wash is the lens in glass — drawn behind the column, so under a dragged
    /// row's opaque ground. The drag tells the row it is lifted, and the row draws its own wash then.
    @Test func aDraggedCurrentRowKeepsItsWash() throws {
        let sidebar = try Self.source("FolderSidebar.swift")
        #expect(sidebar.contains(".environment(\\.folderSidebarRowLifted, isLifted)"))
        #expect(Self.count("if isCurrent { CurrentRowWash(accent: accent) }", in: sidebar) == 2, "a place and a folder")
    }

    @Test func theSidebarsLensesKnowWhatTheColumnShows() throws {
        let sidebar = try Self.source("FolderSidebar.swift")
        // Both hosts — the place's and the folder's.
        #expect(Self.count("visibleRegion: visibleRows)", in: sidebar) == 2)
        #expect(sidebar.contains(".selectionLensTracksVisibleRegion(visibleRows)"))
    }

    @Test func thePreviewToggleWearsGlassOnTheButtonAndKeepsItsFill() throws {
        let views = try Self.source("DashboardViews.swift")
        let style = try #require(views.range(of: ".buttonStyle(.hoverAffordance(previewEnabled.wrappedValue ? .filled : .segment"))
        let after = views[style.upperBound...].drop { $0 != "\n" }.dropFirst()
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // On the button, right after its style: `.filled` flattens its label, and glass inside one
        // renders nothing. Untinted — ON is said by the fill, not by the glass.
        #expect(after?.trimmingCharacters(in: .whitespaces)
                    == ".chromeGlassGround(.capsule, horizontalOutset: PaneNavMetrics.segmentInset / 2, verticalOutset: 0)",
                "the line after Preview's style is \(String(describing: after))")
        #expect(views.contains(".background(previewEnabled.wrappedValue ? AnyShapeStyle(glassHue.accentFillColor)"),
                "Preview's ON fill is gone — under glass ON and OFF read the same")
        #expect(Self.count(".paneNavGlass()", in: views) == 11, "every nav pill's button")
    }
}
