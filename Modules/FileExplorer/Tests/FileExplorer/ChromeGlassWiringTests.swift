import Testing
import Foundation

/// Chrome glass's call sites in FileExplorer: every bar and toolbar button here sits in glass in
/// Frosted and Clear. The seam's behaviour is pinned in Design (`ChromeGlassTests`) and on the
/// pane bar in Dashboard (`ChromeGlassPaneBarTests`); this scan catches a site that lost its glass,
/// which falls back to the Solid look and would never be noticed on screen.
///
/// Read over `SourceText.codeOnly`, because these call sites carry comments naming
/// the very modifiers counted here.
///
/// Where glass may be written (on the button, after its style, never inside a label) is pinned
/// once for every package by the app target's `SelectionLensWiringTests`.
@Suite struct ChromeGlassWiringTests {

    static func source(_ file: String) throws -> String {
        SourceText.codeOnly(try SourceText.fileExplorer(file))
    }

    static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test func theTabStripsPlusAndOverflowWearGlass() throws {
        let strip = try Self.source("PaneTabStrip.swift")
        #expect(Self.count(".chromeGlassGlyphButton()", in: strip) == 1, "the ＋ lost its glass")
        // 3pt past the 16pt AppKit gives the menu, up and down only: the ＋'s 22pt, with the
        // strip's 4pt gap kept. The render is pinned by
        // `SelectionLensCallSiteTests.theOverflowMenusGlassIsAsTallAsTheNewTabButtons`.
        #expect(strip.contains(".chromeGlassGround(.capsule, horizontalOutset: 0, verticalOutset: 3)"),
                "the tab overflow lost its glass, or grows sideways into the last chip")
        // The drag's animations enclose the lens's host, and only where a lens draws: at Solid they
        // would animate a drop's re-windowing, which is instant there. Their curve is
        // `dragEase`'s, pinned with its four sites in `PaneTabStripDragEaseTests`.
        #expect(Self.count(".designAnimation(drawsLens ? Self.dragEase(", in: strip) == 2)
    }

    @Test func comparesHeaderPillsAndGlyphsWearGlass() throws {
        let compare = try Self.source("DifferencesView.swift")
        // Filter, ⋯, Review, Verify, Copy Remaining, Exit Review, and the quiet transfer direction.
        #expect(Self.count(".compareBarGlass(", in: compare) == 7)
        // Every one draws its own hairline, so Clear adds no rim under it.
        #expect(compare.contains("chromeGlassGround(.capsule, rim: false, when: enabled)"))
        #expect(compare.contains(".compareBarGlass(when: weight == .quiet)"),
                "the quiet transfer lost its glass, or the filled one gained it")
        // Every outline pill in the header wears it, each checked within the lines after its own
        // style, rather than two counts that happen to agree.
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

    /// Also the rail: its chosen item sits on the lens and must not lift off it on hover (the
    /// others lift), and the rail scrolls, so a move with either end scrolled out of view switches
    /// instantly rather than gliding across the edge, which only happens if the host is handed
    /// what the rail shows.
    @Test func organizesHeaderControlsWearGlass() throws {
        let lens = try Self.source("LensWorkspaceView.swift")
        #expect(lens.contains(".chromeGlassGround(.capsule, outset: 4)"), "Duplicates' filter menu lost its glass")
        #expect(lens.contains(".pillSurface(.mini, tint: .secondary)\n            .chromeGlassGround(.capsule, rim: false)"),
                "the Source pill lost its glass, or doubles its own edge with Clear's rim")
        #expect(try Self.source("StorageLensView.swift").contains(".chromeGlassTrack()"))
        #expect(Self.count(".chromeHover(onLens: isSelected)", in: lens) == 2)
        #expect(lens.contains("visibleRegion: railVisibleRegion)"))
        #expect(lens.contains(".selectionLensTracksVisibleRegion(railVisibleRegion)"))
    }

    @Test func editsBarsWearGlass() throws {
        let editor = try Self.source("EditorWorkspaceView.swift")
        // A capsule per header button: New Text File and Find don't share one, so the header
        // draws no glass group at all.
        #expect(Self.count(".chromeGlassGroup(", in: editor) == 0, "two of the header's buttons share a capsule again")
        #expect(Self.count(".chromeGlassGlyphButton(tint: accent, shape: .capsule, outset: ChromeGlass.smallGlyphOutset)", in: editor) == 3,
                "New Text File, Find and Expand do not each wear their own glass capsule")
        #expect(try Self.source("EditorHeaderChips.swift")
                    .contains(".chromeGlassGlyphButton(tint: accent, shape: .capsule, outset: ChromeGlass.smallGlyphOutset)"),
                "Close lost its glass")
        let rail = try Self.source("EditorFileRailView.swift")
        #expect(rail.contains(".chromeGlassGroup(.capsule, outset: ChromeGlass.smallGlyphOutset)"))
        #expect(try Self.source("EditorMode.swift").contains(".chromeGlassTrack()"))
        #expect(try Self.source("EditorRailTab.swift").contains(".chromeGlassTrack()"))
    }

    @Test func theCompareCopiesSheetsCloseWearsGlass() throws {
        #expect(try Self.source("CompareCopiesSheet.swift").contains(".chromeGlassGround(.capsule, outset: 2)"))
    }

    /// The hidden mode bars that only reserve a header's height are drawn at Solid: no lens of their
    /// own to run on a mode change, no glass track, and the same height either way.
    ///
    /// Matched across any whitespace between the two modifiers, so a reindent isn't read as a lost
    /// one.
    @Test func editsHeightReservationsRunNoLens() throws {
        let editor = try Self.source("EditorWorkspaceView.swift")
        let reservation = try NSRegularExpression(pattern: #"\.environment\(\\\.selectionLensAppearance, \.today\)\s*\.hidden\(\)"#)
        let found = reservation.numberOfMatches(in: editor, range: NSRange(editor.startIndex..., in: editor))
        #expect(found == 2, "\(found) hidden mode-bar reservations run at Solid — the plain-text and empty-page headers' two expected")
    }

    @Test func theDestinationRailHostsALens() throws {
        let picker = try Self.source("DestinationPicker.swift")
        #expect(picker.contains(".selectionLensHost(Self.railLensChannel, selected: isSearching ? nil : railFocus"))
        #expect(picker.contains(".selectionLensStop(Self.railLensChannel, id: PaneBrowsePath.normalized(path))"))
        // Seeded at init, so opening the picker shows the highlight at rest rather than growing it
        // in. Nothing is picked at open and the rail rests on the item's own folder ("now here"),
        // which `railFocus` derives from the request, at rest from the first frame.
        #expect(picker.contains("_highlighted = State(initialValue: \"\")"))
        #expect(picker.contains("highlighted.isEmpty ? (itemsAreHere ? itemFolder : \"\") : highlighted"))
        // Hosted on the scroll view's content, with the region it shows, as the sidebar's lenses are.
        #expect(picker.contains("visibleRegion: railVisibleRegion)"))
        #expect(picker.contains(".selectionLensTracksVisibleRegion(railVisibleRegion)"))
    }
}
