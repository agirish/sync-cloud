import Testing
import Foundation
import Design
@testable import SyncCloud

/// The app-target half of the selection lens (roadmap RD46): every window hands the stored
/// appearance down, and the controls that live in `MacApp` host their lens.
///
/// Source scans, because these controls cannot be rendered on their own — the workspace bar is a
/// `ContentView` computed property inside a toolbar item. The seam's behaviour is pinned by
/// `SelectionLensTests` (Design), and each package control's wiring by a probe render in its own
/// package; what a scan can and must catch here is a window or a control that forgot to opt in,
/// which would fail safe to today's look and so would never be noticed on screen.
@Suite struct SelectionLensWiringTests {

    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — every check below would be vacuous")
        try #require(text.count > 500, "\(name) is implausibly short — the scans below would be near-vacuous")
        return sourceCodeOnly(text)
    }

    /// Splits `source` at each `Window(` scene and returns each scene's text.
    static func windowScenes(_ source: String) -> [String] {
        let parts = source.components(separatedBy: "Window(\"")
        return Array(parts.dropFirst())
    }

    @Test func everyWindowHandsTheAppearanceToItsLenses() throws {
        let app = try Self.source("SyncCloudApp.swift")
        let scenes = Self.windowScenes(app)
        try #require(scenes.count >= 4, "the app declares at least four windows; found \(scenes.count)")
        for scene in scenes {
            // The scene's own text runs to the next `Window(`; its root modifiers sit inside it.
            let name = scene.prefix(while: { $0 != "\"" })
            #expect(scene.contains(".selectionLensAppearanceFromDefaults()"),
                    "the \(name) window never sets the lens appearance — its controls would stay Solid in every Glass effect")
        }
    }

    @Test func theAppearanceSitsBesideTheFontSizeAtEveryRoot() throws {
        // The two are the same kind of thing — a stored setting read into the environment at a
        // window's root — and a root that has one and not the other is a root someone half-wired.
        let app = try Self.source("SyncCloudApp.swift")
        let fonts = app.components(separatedBy: ".appFontSizeFromSettings()").count - 1
        let lenses = app.components(separatedBy: ".selectionLensAppearanceFromDefaults()").count - 1
        #expect(fonts == lenses, "\(fonts) roots set the font size, \(lenses) set the lens appearance")
    }

    // MARK: - RD46.1 · Workspace bar

    @Test func theWorkspaceBarHostsItsLens() throws {
        let toolbar = try Self.source("ContentView+Toolbar.swift")
        #expect(toolbar.contains(".selectionLensHost(Self.workspaceLensChannel"))
        #expect(toolbar.contains(".selectionLensStop(Self.workspaceLensChannel, id: workspace)"))
    }

    @Test func theWorkspaceBarsChosenLabelIsDarkOnGlass() throws {
        // White on Solid's fill; on a glass lens `.primary` — white there all but vanished.
        let toolbar = try Self.source("ContentView+Toolbar.swift")
        #expect(toolbar.contains(".selectionLensLabelInk(isSelected: isSelected, onFill: onAccent, unselected: Color.secondary)"))
    }

    // MARK: - RD46.12 · Help's topic list

    @Test func helpsTopicListHostsItsLens() throws {
        let help = try Self.source("HelpBook.swift")
        #expect(help.contains(".selectionLensHost(Self.topicLensChannel, selected: selectedTopicID"))
        #expect(help.contains(".selectionLensStop(Self.topicLensChannel, id: topic.id)"))
        // The list scrolls: a move to a topic off screen must switch instantly, which needs the
        // scroll view's visible part handed to the host.
        #expect(help.contains("visibleRegion: visibleTopics)"))
        #expect(help.contains(".selectionLensTracksVisibleRegion(visibleTopics)"))
    }

    @Test func helpsOpenTopicFillIsTodaysMarker() throws {
        let help = try Self.source("HelpBook.swift")
        let marker = try #require(help.range(of: "SelectionLensTodayMarker {"),
                                  "Help's open-topic fill is not wrapped as today's marker")
        #expect(help[marker.upperBound...].prefix(240).contains(".fill(accentFill)"))
    }

    /// ⌘N from another workspace sets Edit's rail tab BEFORE it switches there, so the rail is built
    /// on its files half rather than switching to it in its first update — which glided its lens
    /// across the tabs of a window nobody had touched.
    @Test func newTextFileSetsTheRailTabBeforeTheRailIsBuilt() throws {
        let editor = try Self.source("ContentView+Editor.swift")
        let body = try #require(editor.range(of: "var shortcutNewTextFile"), "no ⌘N handler")
        let rest = editor[body.upperBound...]
        let tab = try #require(rest.range(of: "editorRailTab = .files"), "⌘N no longer sets the rail tab")
        let switchTo = try #require(rest.range(of: "selectedWorkspace = .editor"))
        #expect(tab.lowerBound < switchTo.lowerBound, "the rail tab is set after the switch that builds the rail")
    }

    /// The `[glass]` line is written at launch and again on every change that would alter it.
    @Test func theGlassLineFollowsTheSettingsThroughTheSession() throws {
        let app = try Self.source("SyncCloudApp.swift")
        #expect(app.contains("glassLogLine.start()"))
        #expect(app.contains("UserDefaults.didChangeNotification"))
        #expect(app.contains("NSWorkspace.accessibilityDisplayOptionsDidChangeNotification"))
        #expect(app.contains("increasedContrast: workspace.accessibilityDisplayShouldIncreaseContrast"))
        // Never a queue-based observer: see the test below for what one did.
        #expect(!app.contains("queue: .main) { [weak self] _ in\n                MainActor.assumeIsolated { self?.log() }"))
    }

    /// **A defaults write off the main thread never waits for it.** The `[glass]` line's first
    /// observer was `queue: .main`, which makes the POSTER wait for the main thread: a background
    /// writer holding a lock waited on a main thread that was waiting on that lock, and the test host
    /// hung for good (2026-10-03, `FilingSpendStore`). Here the main thread is held while another
    /// thread writes a default; with the old observer the write cannot finish until the hold ends,
    /// and the hold gives up after five seconds and says so.
    @Test @MainActor func aDefaultsWriteOffTheMainThreadNeverWaitsForIt() throws {
        let line = GlassLogLine()
        line.start()
        defer { line.stop() }
        let suite = "SelectionLensWiringTests.glassLine-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let written = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            UserDefaults(suiteName: suite)?.set(1, forKey: "probe")
            written.signal()
        }
        // The main thread, held — as a lock holder's main-thread waiter would hold it.
        #expect(written.wait(timeout: .now() + 5) == .success,
                "a background defaults write waited on the main thread — a lock held across one deadlocks")
    }

    @Test func helpsOpenTopicIsDarkOnGlass() throws {
        // The glyph and the title, each on-fill white at Solid and on dark glass, `.primary` on light glass.
        let help = try Self.source("HelpBook.swift")
        #expect(help.components(separatedBy: ".selectionLensLabelInk(isSelected: isSelected, onFill: onAccent").count - 1 == 2)
    }

    // MARK: - RD46.15 · The setup form's accent swatches

    @Test func theSetupSwatchesHostTheirLens() throws {
        let screen = try Self.source("Setup/AppearanceScreen.swift")
        #expect(screen.contains(".selectionLensHost(Self.swatchLensChannel"))
        #expect(screen.contains(".selectionLensStop(Self.swatchLensChannel, id: offered)"))
        // Today's ring is the marker the halo replaces — drawn as well, it would ring the swatch twice.
        let marker = try #require(screen.range(of: "SelectionLensTodayMarker {"),
                                  "the setup swatch's ring is not wrapped as today's marker")
        #expect(screen[marker.upperBound...].prefix(120).contains("strokeBorder(.tint, lineWidth: 2)"))
    }

    @Test func theSetupHaloIsNeverTintedAndMatchesTodaysRing() {
        // It rings a colour, so it must not wear one; and it is today's 2pt ring, carried.
        #expect(AppearanceScreen.swatchLensStyle.markerOpacity == 0)
        #expect(AppearanceScreen.swatchLensStyle.ring?.width == 2)
        #expect(AppearanceScreen.swatchLensStyle.outset == 0,
                "the setup ring already sits outside the swatch, on its 3pt padding — an outset would push it further")
    }

    @Test func theWorkspaceBarsSlidingCapsuleIsTodaysMarker() throws {
        // Solid keeps the 0.22 s matched-geometry slide; it must be the thing the lens replaces,
        // or Frosted and Clear would draw the opaque pill AND the glass.
        let toolbar = try Self.source("ContentView+Toolbar.swift")
        let marker = try #require(toolbar.range(of: "SelectionLensTodayMarker {"),
                                  "the bar's capsule is not wrapped as today's marker")
        let after = toolbar[marker.upperBound...].prefix(400)
        #expect(after.contains("matchedGeometryEffect(id: Self.workspaceMarkerID"))
    }

    // MARK: - The chosen label on glass

    /// **Every lens that stands for a solid fill colours its labels for glass.** Such a control's
    /// chosen label is white at Solid, because its fill was chosen to carry white; on the lens
    /// there is no fill, only glass, and on light glass white all but vanished (reported
    /// 2026-10-03). `selectionLensLabelInk` gives it `.primary`, black, on light glass — and a
    /// control added with a `.fill` lens and the old ternary would ship white-on-glass with every
    /// test of its geometry green. Wash lenses are exempt: their labels were never white.
    ///
    /// Counted per file — at least as many label-ink calls as fill hosts — so one control's ink
    /// cannot vouch for a second fill lens added beside it. (A style passed by name rather than
    /// written `.fill(` inline is not seen; none is today, and the floor below would not notice one.)
    @Test func everyFillLensColoursItsLabelsForGlass() throws {
        var fillHosts = 0
        var missing: [String] = []
        let host = Array(".selectionLensHost(".utf8)
        for (path, text) in try Self.everySource() where !Self.offsets(of: host, in: Array(text.utf8)).isEmpty {
            let code = sourceCodeOnly(text)
            let fills = argumentLists(of: ".selectionLensHost", in: code).filter { $0.contains("style: .fill(") }
            fillHosts += fills.count
            let inks = code.components(separatedBy: ".selectionLensLabelInk(").count - 1
            if inks < fills.count { missing.append("\(path) (\(fills.count) fill lenses, \(inks) label inks)") }
        }
        // The workspace bar, Tree · Columns, the log's chips, Edit's two capsules, Storage's, the
        // Settings and Help rails, and the destination picker's.
        #expect(fillHosts >= 9, "only \(fillHosts) fill lenses found — the reader is broken")
        #expect(missing.isEmpty, "a fill lens whose labels stay white on glass: \(missing)")
    }

    // MARK: - Where glass may be written

    /// What draws glass, or a lens's glass: each must go ON a button, after its style — never
    /// inside its label.
    static let glassModifiers = [".chromeGlassGround(", ".chromeGlassGroup(", ".chromeGlassGlyphButton(",
                                 ".chromeGlassTrack()", ".paneNavGlass()", ".compareBarGlass(",
                                 ".selectionLensHost("]

    /// Every Swift file under `Modules/*/Sources` and `MacApp/`, by path relative to the repo.
    static func everySource() throws -> [(path: String, text: String)] {
        let root = macAppDirectory().deletingLastPathComponent()
        var files: [(String, String)] = []
        for top in ["Modules", "MacApp"] {
            let base = root.appendingPathComponent(top)
            let walk = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil),
                                    "cannot walk \(top)/")
            for case let url as URL in walk where url.pathExtension == "swift" {
                let path = String(url.path.dropFirst(root.path.count + 1))
                guard top == "MacApp" || path.contains("/Sources/") else { continue }
                files.append((path, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return files
    }

    /// Every offset of `word` in `bytes`, by `memmem` — string, comment or code alike; the caller
    /// asks the lexer which.
    static func offsets(of word: [UInt8], in bytes: [UInt8]) -> [Int] {
        bytes.withUnsafeBytes { big in
            word.withUnsafeBytes { little in
                guard let base = big.baseAddress, let needle = little.baseAddress else { return [] }
                var hits: [Int] = []
                var from = 0
                while from < big.count, let hit = memmem(base + from, big.count - from, needle, little.count) {
                    let at = base.distance(to: UnsafeRawPointer(hit))
                    hits.append(at)
                    from = at + 1
                }
                return hits
            }
        }
    }

    private static let labelWord = Array("label:".utf8), buttonWord = Array("Button(".utf8),
                       actionWord = Array("action:".utf8)

    /// The byte ranges of every button and menu LABEL in `source`: a `label: {` closure, or the
    /// trailing closure of `Button(action: …)`. (`Button("Title") { … }`'s trailing closure is its
    /// action, and `Menu { … }`'s its content — neither is a label.) Braces and parentheses are
    /// counted in code only, so a `{` in a string or a comment cannot end a label early.
    static func labelBlocks(_ source: LexedSource) -> [Range<Int>] {
        let b = source.bytes, r = source.roles, n = b.count
        func code(at i: Int, _ word: [UInt8]) -> Bool {
            guard i + word.count <= n else { return false }
            for k in 0..<word.count where b[i + k] != word[k] || r[i + k] != .code { return false }
            return true
        }
        func matching(_ open: Int) -> Int? {
            let opener = b[open], closer = opener == UInt8(ascii: "(") ? UInt8(ascii: ")") : UInt8(ascii: "}")
            var depth = 0
            for i in open..<n where r[i] == .code {
                if b[i] == opener { depth += 1 } else if b[i] == closer { depth -= 1; if depth == 0 { return i } }
            }
            return nil
        }
        func nextCode(after i: Int) -> Int? {
            var j = i + 1
            while j < n, r[j] != .code || b[j] == 32 || b[j] == 9 || b[j] == 10 || b[j] == 13 { j += 1 }
            return j < n ? j : nil
        }
        func isIdentifier(_ c: UInt8) -> Bool {
            (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 95
        }
        var opens: [Int] = []
        for i in offsets(of: labelWord, in: b) where code(at: i, labelWord) {
            if let j = nextCode(after: i + labelWord.count - 1), b[j] == UInt8(ascii: "{") { opens.append(j) }
        }
        for i in offsets(of: buttonWord, in: b) where code(at: i, buttonWord) && (i == 0 || !isIdentifier(b[i - 1])) {
            let paren = i + buttonWord.count - 1
            if let first = nextCode(after: paren), code(at: first, actionWord),
               let close = matching(paren), let j = nextCode(after: close), b[j] == UInt8(ascii: "{") {
                opens.append(j)
            }
        }
        return opens.compactMap { open in matching(open).map { open..<$0 } }
    }

    /// **No glass inside a button's label, anywhere.** `.filled`, `.circular`, `.chrome` and
    /// `.actionBar` flatten their label into a compositing group, and Liquid Glass renders NOTHING
    /// through one — while every offscreen test still passes, because glass draws nothing offscreen
    /// either. That is how the first chrome glass shipped invisible on half the bar. The fix was to
    /// put glass on the button, after its style; this is what keeps it there, in every package.
    ///
    /// Searched with `memmem` and lexed only where a glass modifier occurs: the first version
    /// compared byte by byte over the whole repo — 10 MB — and took 25 s in a Debug test build,
    /// the kind of synchronous scan that starves the pool every suite here shares (see `lexed`).
    @Test func noGlassIsWrittenInsideAButtonsLabel() throws {
        var files = 0, labels = 0, uses = 0
        var offenders: [String] = []
        let tokens = Self.glassModifiers.map { Array($0.utf8) }
        for (path, text) in try Self.everySource() {
            let bytes = Array(text.utf8)
            let hits = tokens.map { Self.offsets(of: $0, in: bytes) }
            guard hits.contains(where: { !$0.isEmpty }) else { continue }
            files += 1
            let source = lexed(text)
            let blocks = Self.labelBlocks(source)
            labels += blocks.count
            for (offsets, name) in zip(hits, Self.glassModifiers) {
                for i in offsets where source.roles[i] == .code {
                    uses += 1
                    if blocks.contains(where: { $0.contains(i) }) {
                        let line = bytes[..<i].reduce(1) { $1 == 10 ? $0 + 1 : $0 }
                        offenders.append("\(path):\(line) \(name)")
                    }
                }
            }
        }
        // Not vacuous: the reader found the files that wear glass, their labels, and the glass.
        #expect(files > 20, "only \(files) files wear glass — the reader is broken")
        #expect(labels > 100, "only \(labels) button labels found in \(files) files — the reader is broken")
        #expect(uses > 40, "only \(uses) glass call sites found — the reader is broken")
        #expect(offenders.isEmpty, "glass written inside a button's label:\n\(offenders.joined(separator: "\n"))")
    }

    /// The reader itself, on text whose answer is known.
    @Test func theLabelReaderFindsLabelsAndOnlyLabels() {
        func blocks(_ text: String) -> [String] {
            let source = lexed(text)
            return Self.labelBlocks(source).map { String(decoding: source.bytes[$0], as: UTF8.self) }
        }
        #expect(blocks("Button { go() } label: { Text(\"a\").chromeGlassTrack() }") == ["{ Text(\"a\").chromeGlassTrack() "])
        #expect(blocks("Button(action: go) { Image(systemName: \"x\") }") == ["{ Image(systemName: \"x\") "])
        // An action, not a label; a menu's content, not a label.
        #expect(blocks("Button(\"Go\") { go() }").isEmpty)
        #expect(blocks("Menu { Button(\"a\") {} }").isEmpty)
        // A brace in a string does not end the label.
        #expect(blocks("Menu {} label: { Text(\"}\") ; x }") == ["{ Text(\"}\") ; x "])
        // A name that merely ends in Button is not one.
        #expect(blocks("CloseButton(action: go) { y }").isEmpty)
    }
}
