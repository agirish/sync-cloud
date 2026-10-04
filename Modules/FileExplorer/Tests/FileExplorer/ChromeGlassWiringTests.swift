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
        // 3pt past the 16pt AppKit gives the menu, up and down only — the ＋'s 22pt, and the strip's
        // 4pt gap kept; the render is `SelectionLensCallSiteTests.theOverflowMenusGlassIsAsTallAsTheNewTabButtons`.
        #expect(strip.contains(".chromeGlassGround(.capsule, horizontalOutset: 0, verticalOutset: 3)"),
                "the tab overflow lost its glass, or grows sideways into the last chip")
        // The drag's animations enclose the lens's host, and only where a lens draws: at Solid they
        // would animate a drop's re-windowing, which was always instant there.
        #expect(Self.count(".designAnimation(drawsLens ? .easeOut(duration: 0.16) : nil", in: strip) == 2)
    }

    @Test func comparesHeaderPillsAndGlyphsWearGlass() throws {
        let compare = try Self.source("DifferencesView.swift")
        // Filter, ⋯, Review, Verify, Copy Remaining, Exit Review — and the quiet transfer direction.
        #expect(Self.count(".compareBarGlass(", in: compare) == 7)
        // Every one draws its own hairline, so Clear adds no rim under it.
        #expect(compare.contains("chromeGlassGround(.capsule, rim: false, when: enabled)"))
        #expect(compare.contains(".compareBarGlass(when: weight == .quiet)"),
                "the quiet transfer lost its glass, or the filled one gained it")
        // Every outline pill in the header wears it — each one's own, within the lines after its
        // style — rather than two counts that happen to agree.
        let lines = compare.components(separatedBy: "\n")
        let pills = lines.indices.filter { lines[$0].contains(".buttonStyle(.actionBar(.outline") }
        #expect(pills.count == 6)
        for i in pills {
            let after = lines[(i + 1)..<min(lines.count, i + 4)]
            #expect(after.contains { $0.contains(".compareBarGlass(") },
                    "the outline pill at code line \(i + 1) has no glass of its own")
        }
        // Fold all and the list's collapse chevron: glyph buttons, 2pt past their 22pt.
        #expect(Self.count(".chromeGlassGlyphButton(tint: glassHue.accentColor, outset: 2)", in: compare) == 2)
    }

    @Test func organizesHeaderControlsWearGlass() throws {
        let lens = try Self.source("LensWorkspaceView.swift")
        #expect(lens.contains(".chromeGlassGround(.capsule, outset: 4)"), "Duplicates' filter menu lost its glass")
        #expect(lens.contains(".pillSurface(.mini, tint: .secondary)\n            .chromeGlassGround(.capsule, rim: false)"),
                "the Source pill lost its glass, or doubles its own edge with Clear's rim")
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
    /// The rail's chosen item sits on the lens and must not lift off it on hover; the others lift.
    @Test func organizesChosenRailItemStaysSeatedOnItsLens() throws {
        #expect(Self.count(".chromeHover(onLens: isSelected)", in: try Self.source("LensWorkspaceView.swift")) == 2)
    }

    /// The hidden mode bars that only reserve a header's height are drawn at Solid: no lens of their
    /// own to run on a mode change, no glass track — and the same height either way.
    ///
    /// Matched across any whitespace between the two modifiers: it counted them by their exact
    /// indentation, so moving the empty page's reservation one level out (TE48) read as a lost one.
    @Test func editsHeightReservationsRunNoLens() throws {
        let editor = try Self.source("EditorWorkspaceView.swift")
        let reservation = try NSRegularExpression(pattern: #"\.environment\(\\\.selectionLensAppearance, \.today\)\s*\.hidden\(\)"#)
        let found = reservation.numberOfMatches(in: editor, range: NSRange(editor.startIndex..., in: editor))
        #expect(found == 2, "\(found) hidden mode-bar reservations run at Solid — the plain-text and empty-page headers' two expected")
    }

    @Test func theDestinationRailHostsALens() throws {
        let picker = try Self.source("DestinationPicker.swift")
        #expect(picker.contains(".selectionLensHost(Self.railLensChannel, selected: isSearching ? nil : highlighted"))
        #expect(picker.contains(".selectionLensStop(Self.railLensChannel, id: PaneBrowsePath.normalized(path))"))
        // Seeded at init, so opening the picker shows the highlight at rest rather than growing it in.
        #expect(picker.contains("_highlighted = State(initialValue: highlighted)"))
    }

    @Test func organizesRailHostReadsWhatTheRailShows() throws {
        let lens = try Self.source("LensWorkspaceView.swift")
        #expect(lens.contains("visibleRegion: railVisibleRegion)"))
        #expect(lens.contains(".selectionLensTracksVisibleRegion(railVisibleRegion)"))
    }
}
