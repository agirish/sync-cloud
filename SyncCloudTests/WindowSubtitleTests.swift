@testable import SyncCloud
import Sync
import Testing
import AppKit
import SwiftUI

/// **The window's name — the wording, and that it reaches the real `NSWindow`.**
@Suite struct WindowSubtitleTests {

    private func source(_ provider: String?, _ path: String) -> WindowSubtitle.Source {
        WindowSubtitle.Source(provider: provider, relativePath: path)
    }

    @Test func aComparisonNamesBothSides() {
        #expect(WindowSubtitle.text(mode: .compare,
                                    left: source("iCloud", "Documents"),
                                    right: source("Dropbox", "Documents"))
                == "iCloud/Documents ⇄ Dropbox/Documents")
    }

    /// A lens works one tree, so naming a second one would name a pane that is not on screen.
    @Test func aSingleSourceWorkspaceNamesOnlyTheSourceItIsWorking() {
        #expect(WindowSubtitle.text(mode: .singleSource,
                                    left: source("iCloud", "Documents"),
                                    right: source("Dropbox", "Photos"))
                == "iCloud/Documents")
    }

    /// At a provider's root there is no folder to name, and a trailing slash would claim one.
    @Test func aPaneAtItsRootIsJustTheProvider() {
        #expect(WindowSubtitle.describe(source("iCloud", "")) == "iCloud")
        #expect(WindowSubtitle.describe(source("iCloud", "/")) == "iCloud")
    }

    /// `paneLocation` returns a relative path, but the panes have carried a leading slash before
    /// now and a doubled one reads as an absolute path in a name that is not.
    @Test func aLeadingOrTrailingSlashDoesNotDoubleUp() {
        #expect(WindowSubtitle.describe(source("iCloud", "/Documents/Work/")) == "iCloud/Documents/Work")
    }

    /// A provider removed while a tab still remembers it. The window is still meaningfully the
    /// other side's window — better in a Window menu than falling back to the app's name.
    @Test func anUnresolvedSideDropsOutRatherThanEmptyingTheWholeName() {
        #expect(WindowSubtitle.text(mode: .compare,
                                    left: source(nil, "Documents"),
                                    right: source("Dropbox", "Photos"))
                == "Dropbox/Photos")
        #expect(WindowSubtitle.text(mode: .compare,
                                    left: source("", "Documents"),
                                    right: source("Dropbox", "Photos"))
                == "Dropbox/Photos")
    }

    /// Nothing configured at all — nothing to say, and the binder clears the subtitle so the
    /// Window menu falls back to the scene's own "SyncCloud".
    @Test func nothingResolvedMeansNoNameToSet() {
        #expect(WindowSubtitle.text(mode: .compare, left: source(nil, ""), right: source(nil, "")) == nil)
    }

    /// Two tabs on one provider are distinguished by their paths, without the "(left)"/"(right)"
    /// disambiguation `PaneProviderNames` adds for pane headers — which would read as noise here.
    @Test func twoTabsOnOneProviderAreToldApartByPath() {
        #expect(WindowSubtitle.text(mode: .compare,
                                    left: source("iCloud", "Documents"),
                                    right: source("iCloud", "Photos"))
                == "iCloud/Documents ⇄ iCloud/Photos")
    }
}

/// **The binder, against a real window.**
///
/// The rule above is a string function; this is the half that can be wired wrong — and it has two
/// entry points that each miss half the cases on their own (`view.window` is nil during the first
/// `updateNSView`, and `viewDidMoveToWindow` fires once).
@MainActor
@Suite struct WindowChromeBinderTests {

    private func window() -> NSWindow {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "SyncCloud"
        return w
    }

    /// Added to a window *after* the probe already holds a name — the first-mount order, where
    /// `updateNSView` has nothing to write to yet.
    @Test func aProbeAddedToAWindowNamesItOnArrival() {
        let host = window()
        let probe = WindowChromeBinder.Probe(subtitle: "iCloud/Documents ⇄ Dropbox/Documents")
        host.contentView?.addSubview(probe)
        #expect(host.subtitle == "iCloud/Documents ⇄ Dropbox/Documents")
        #expect(host.title == "SyncCloud", "the scene's own title is not the binder's to change")
    }

    /// And every later change — navigating, switching tabs, swapping the panes.
    @Test func aLaterChangeReachesTheWindowToo() {
        let host = window()
        let probe = WindowChromeBinder.Probe(subtitle: "iCloud")
        host.contentView?.addSubview(probe)
        probe.subtitle = "Dropbox/Photos"
        #expect(host.subtitle == "Dropbox/Photos")
    }

    /// Nothing to say clears the subtitle rather than leaving a pair that is no longer true.
    @Test func nothingToSayClearsTheSubtitle() {
        let host = window()
        let probe = WindowChromeBinder.Probe(subtitle: "iCloud/Documents")
        host.contentView?.addSubview(probe)
        probe.subtitle = nil
        #expect(host.subtitle == "")
        #expect(host.title == "SyncCloud")
    }

    /// **How AppKit actually spells a window in the Window menu — measured, and the opposite of
    /// what this was first built on.**
    ///
    /// The first draft set `title` on the reasoning that a `.hiddenTitleBar` window draws no
    /// subtitle, so nothing could be reading it. AppKit composes the window-list entry from
    /// **both**, as `"<title> (<subtitle>)"` — so setting `title` too would have printed the pair
    /// twice in one entry, and setting only `title` would have thrown away the better spelling.
    ///
    /// The window is put in the list under a placeholder and then each property is set in turn, so
    /// what the entry says afterwards is AppKit's answer and not one this test supplied.
    @Test func theWindowListEntryComposesTitleAndSubtitle() throws {
        let host = window()
        // Far off any real display: AppKit lists a window it is managing whether or not anyone can
        // see it, and this suite must not put anything on the user's screen.
        host.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        host.title = "placeholder"
        host.orderFront(nil)
        defer { host.orderOut(nil); NSApp.removeWindowsItem(host) }

        func entries() -> [String] { NSApp.windowsMenu?.items.map(\.title) ?? [] }
        try #require(entries().contains("placeholder"),
                     "the window never entered the windows menu — this check would be vacuous")

        host.subtitle = "iCloud/Documents ⇄ Dropbox/Documents"
        #expect(entries().contains("placeholder (iCloud/Documents ⇄ Dropbox/Documents)"),
                "the subtitle is not composed into the window list: \(entries())")

        // And the title still drives its half, which is why the binder leaves it to the scene.
        host.title = "SyncCloud"
        #expect(entries().contains("SyncCloud (iCloud/Documents ⇄ Dropbox/Documents)"),
                "the composed entry did not follow the title: \(entries())")
    }
}


/// **The wiring, read off `ContentView`'s source.**
///
/// The rule and the binder are both tested, and both would stay green if nothing ever *mounted* the
/// binder — the window would simply keep the scene's bare "SyncCloud" and no assertion anywhere
/// would notice. That is the same failure `ShortcutCommandsTests` guards against for a deleted
/// `.focusedSceneValue`: a feature that is fully built, fully tested, and not connected.
@Suite struct WindowSubtitleWiringTests {

    static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(file)
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read \(file) — this scan would be vacuous")
        try #require(raw.count > 5000, "\(file) is implausibly short — the scan is vacuous")
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    @Test func theBinderIsActuallyMounted() throws {
        let content = try Self.source("MacApp/ContentView.swift")
        #expect(content.contains("WindowChromeBinder(subtitle: windowSubtitleText)"),
                "nothing mounts WindowChromeBinder — the window keeps the scene's bare title and no other test can tell")
    }

    /// And the name it is handed comes from the rule rather than being assembled at the call site,
    /// which is where the "⇄ on a lens workspace" bug would live.
    @Test func theNameComesFromTheRule() throws {
        let content = try Self.source("MacApp/ContentView.swift")
        #expect(content.contains("WindowSubtitle.text(mode: layoutMode"),
                "windowSubtitleText builds the name itself instead of going through WindowSubtitle.text")
    }
}

/// **Paste's enablement asks the same question the paste does.**
///
/// Both sites used to ask `clipboardNodes.isEmpty`, which was right while the app's list was the
/// only clipboard and now greys out a paste of files copied in Finder. Neither site is reachable
/// from a test — one is a `ContentView` property, the other a delegate built from a dozen live
/// values — so this is a source scan, and it is scoped to the one regression it can actually see:
/// a site reverting to the in-app-only check.
@Suite struct PasteEnablementWiringTests {

    @Test(arguments: ["MacApp/ShortcutCommands.swift", "MacApp/PaneActionDelegate.swift"])
    func bothEnablementSitesGoThroughTheSharedRule(file: String) throws {
        let source = try WindowSubtitleWiringTests.source(file)
        #expect(source.contains("ClipboardSource.current("),
                "\(file) decides Paste's enablement without the rule the paste itself uses")
    }
}
