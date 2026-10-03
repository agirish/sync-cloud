import Testing
import Foundation

/// Chrome glass's call sites in FileExplorer (RD46 follow-up, 2026-10-03): every bar and toolbar
/// button here sits in glass in Frosted and Clear. The seam's behaviour is rendered and pinned in
/// Design (`ChromeGlassTests`) and on the pane bar in Dashboard (`ChromeGlassPaneBarTests`); what a
/// scan can and must catch here is a site that lost its glass — which fails safe to the Solid look
/// in every appearance, and so would never be noticed on screen.
///
/// Read over `OrganizeScopeCallSiteTests.codeOnly`: these call sites carry comments that name the
/// very modifiers counted here, and a count over the raw text passed with the code gone.
///
/// Where glass may be WRITTEN — on the button, after its style, never inside a label — is pinned
/// once for every package by the app target's `SelectionLensWiringTests`.
@Suite struct ChromeGlassWiringTests {

    static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/\(file)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(file) — every scan here would be vacuous")
        try #require(text.count > 500, "\(file) read as \(text.count) characters — truncated?")
        return OrganizeScopeCallSiteTests.codeOnly(text)
    }

    static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test func theTabStripsPlusAndOverflowWearGlass() throws {
        let strip = try Self.source("PaneTabStrip.swift")
        #expect(Self.count(".chromeGlassGlyphButton()", in: strip) == 1, "the ＋ lost its glass")
        // 3pt past the 16pt AppKit gives the menu — the ＋'s 22pt; the render is
        // `SelectionLensCallSiteTests.theOverflowMenusGlassIsAsTallAsTheNewTabButtons`.
        #expect(strip.contains(".chromeGlassGround(.capsule, outset: 3)"), "the tab overflow lost its glass")
    }

    @Test func comparesHeaderPillsAndGlyphsWearGlass() throws {
        let compare = try Self.source("DifferencesView.swift")
        // Filter, ⋯, Review, Verify, Copy Remaining, Exit Review — and the quiet transfer direction.
        #expect(Self.count(".compareBarGlass(", in: compare) == 7)
        #expect(compare.contains(".compareBarGlass(when: weight == .quiet)"),
                "the quiet transfer lost its glass, or the filled one gained it")
        // Every outline pill in the header wears it: no `.actionBar(.outline` without its glass.
        #expect(Self.count(".buttonStyle(.actionBar(.outline", in: compare) == 6)
        // Fold all and the list's collapse chevron: glyph buttons, 2pt past their 22pt.
        #expect(Self.count(".chromeGlassGlyphButton(tint: glassHue.accentColor, outset: 2)", in: compare) == 2)
    }

    @Test func organizesHeaderControlsWearGlass() throws {
        let lens = try Self.source("LensWorkspaceView.swift")
        #expect(lens.contains(".chromeGlassGround(.capsule, outset: 4)"), "Duplicates' filter menu lost its glass")
        #expect(lens.contains(".pillSurface(.mini, tint: .secondary)\n            .chromeGlassGround(.capsule)"),
                "the Source pill lost its glass")
        #expect(try Self.source("StorageLensView.swift").contains(".chromeGlassTrack()"))
    }

    @Test func editsBarsWearGlass() throws {
        let editor = try Self.source("EditorWorkspaceView.swift")
        // ＋/Find/Just-the-text in the document's header and ＋ in the empty page's — one capsule each.
        #expect(Self.count(".chromeGlassGroup(.capsule, outset: ChromeGlass.smallGlyphOutset)", in: editor) == 2)
        #expect(editor.contains(".chromeGlassGlyphButton(tint: accent, outset: ChromeGlass.smallGlyphOutset)"),
                "Close lost its glass")
        let rail = try Self.source("EditorFileRailView.swift")
        #expect(rail.contains(".chromeGlassGroup(.capsule, outset: ChromeGlass.smallGlyphOutset)"))
        #expect(try Self.source("EditorMode.swift").contains(".chromeGlassTrack()"))
        #expect(try Self.source("EditorRailTab.swift").contains(".chromeGlassTrack()"))
    }

    @Test func theCompareCopiesSheetsCloseWearsGlass() throws {
        #expect(try Self.source("CompareCopiesSheet.swift").contains(".chromeGlassGround(.capsule, outset: 2)"))
    }

    /// The rail scrolls, and a move with either end scrolled out of view switches instantly rather
    /// than gliding across the edge — which only happens if the host is handed what the rail shows.
    @Test func organizesRailHostReadsWhatTheRailShows() throws {
        let lens = try Self.source("LensWorkspaceView.swift")
        #expect(lens.contains("visibleRegion: railVisibleRegion)"))
        #expect(lens.contains(".selectionLensTracksVisibleRegion(railVisibleRegion)"))
    }
}
