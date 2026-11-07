import Testing
import Foundation

/// Chrome glass's call sites in Dashboard beyond what `ChromeGlassPaneBarTests` renders: the
/// breadcrumb's source pill, the Activity Log and Sync History headers, and the log's level chips.
/// A site that loses its glass falls back to the Solid look, so only a scan sees it. Read through
/// `DashboardSource.codeOnly`, because these sites carry comments naming the very
/// modifiers counted here.
@Suite struct ChromeGlassWiringTests {

    static func source(_ file: String) throws -> String {
        try DashboardSource.read(file, codeOnly: true)
    }

    static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test func theBreadcrumbsSourcePillWearsGlassUnderItsBrandWash() throws {
        let crumb = try Self.source("PaneBreadcrumb.swift")
        let wash = try #require(crumb.range(of: ".fill(hue?.tint.opacity(SourceChip.washOpacity) ?? .clear)"))
        // Gated on the wash's own optional, so a crumb with no source stays bare. No rim: the brand
        // hairline is the pill's edge, and Clear's rim would double it.
        let glass = try #require(crumb.range(of: ".chromeGlassGround(.capsule, rim: false, when: hue != nil)"),
                                 "the source pill lost its glass, or wears it with no source, or doubles its edge")
        // After the wash in the chain, so the glass is behind it and the brand colour stays painted.
        #expect(glass.lowerBound > wash.upperBound)
    }

    @Test func theLogAndHistoryHeadersUseGlassButtons() throws {
        #expect(Self.count(".chromeGlassBorderedButtonStyle()", in: try Self.source("LogViewer.swift")) == 4,
                "Copy, Copy Log for Sharing, Clear and Open log file")
        #expect(Self.count(".chromeGlassBorderedButtonStyle()", in: try Self.source("SyncHistoryView.swift")) == 4,
                "Undo Last Run, Export and Clear (a menu beside settings changes, a button without) — one header, one kind of button")
    }

    /// The level chips are a pick-one row like every other that wears a lens. The row scrolls, so
    /// the host gets what the scroll view shows, and a move off either edge switches instantly.
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

    /// The current row's wash is the lens in glass, drawn behind the column and so under a dragged
    /// row's opaque ground. The drag tells the row it is lifted, and the row then draws its own wash.
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

    @Test func everyNavPillWearsGlassOnItsButton() throws {
        let views = try Self.source("DashboardViews.swift")
        #expect(Self.count(".paneNavGlass()", in: views) == 12, "every nav pill's button")
    }
}
