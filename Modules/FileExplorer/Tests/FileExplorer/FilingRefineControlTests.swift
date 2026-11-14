import Testing
import AppKit
import SwiftUI
@testable import Sync
@testable import FileExplorer

/// Does the Refine control reach the screen, and does it say the right thing? Pixels, because
/// nothing else is open: `fittingSize` cannot see the label (the lens fills a fixed frame), and a
/// caption assertion passes vacuously with no assistive client attached to the test process.
///
/// Every setting lives in a scratch suite the manager owns, never the standard domain: a test that
/// shares one store with another renders whichever state won the race. `.serialized` keeps the tests
/// in this process apart but cannot reach another one, and under `swift test` the standard domain is
/// one plist shared by every test process on the machine, which is also the CI runner.
///
/// `.machinePinned(.pixelSampling)` because it reads pixels back out of a live renderer
/// (`colorAt(`). The self-hosted run excludes only `liveProfile`, so this still runs there.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct FilingRefineControlTests {

    private static let canvas = CGSize(width: 900, height: 620)

    private static func suggestion(_ name: String) -> FilingSuggestion {
        FilingSuggestion(
            filePath: "/root/Downloads/\(name)", fileName: name, size: 4_096,
            modificationDate: Date(timeIntervalSince1970: 0),
            candidates: [FilingDestination(path: "/root/Documents/Family", confidence: .high,
                                           reasons: ["test"], newSegments: [])],
            providerRoot: "/root")
    }

    /// A manager holding a completed Organize scan of `/root/Downloads`, with the cached taxonomy a
    /// refine pass needs. Every setting goes to a fresh scratch suite, `filingContentDefaults`, which
    /// `mount` hands the view through `.defaultAppStorage`, so the button and the manager read one
    /// store and no two mounts share one.
    private static func manager(cloudOn: Bool, routesTo: String? = nil) -> FileSyncManager {
        let m = FileSyncManager()
        let defaults = ScratchDefaults("FilingRefineControlTests")
        m.filingContentDefaults = defaults
        // `routesTo` stands in for the app's router; nil falls back to what the toggle configures.
        if let routesTo { m.filingBackendIdentity = { _ in routesTo } }
        m.publishFilingSuggestions([suggestion("a.pdf"), suggestion("b.pdf")])
        m.hasSuggestedFiling = true
        m.filingScanFolder = "/root/Downloads"
        m.filingLastProviderRoot = "/root"
        m.filingLastTaxonomyFolders = ["Documents", "Documents/Family"]
        m.filingLastExistingFolders = ["Documents", "Documents/Family"]
        m.filingClassifier = { _, _, _ in [:] }
        // Organize opens on its overview, where no lens's controls are drawn, so a filing fixture
        // must name its lens or every assertion fails as "painted nothing". It goes in the same suite
        // as the cloud settings: `.defaultAppStorage` redirects every `@AppStorage` beneath it, so a
        // store holding only this key would shadow the settings these tests vary.
        defaults.set(OrganizeLens.toFile.rawValue, forKey: OrganizeLens.defaultsKey)
        // `cloudOn` is "a Claude key is saved": the app's seam, and the only opt-in.
        m.filingCloudRefineConfigured = { cloudOn }
        return m
    }

    private final class Mounted {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        init(host: NSHostingView<AnyView>, window: NSWindow) {
            self.host = host
            self.window = window
        }
    }

    /// The window background is not decoration: without one the content composites against the
    /// borderless window's own buffer and every comparison reads as zero difference.
    private func mount(_ manager: FileSyncManager, configure: (() -> Void)? = nil) -> Mounted {
        let subject = LensWorkspaceView(syncManager: manager, lens: .filing,
                               providerName: "Projects", scanTargetFolder: "/root/Downloads",
                               onFindDuplicates: {}, onConfigureCloudRefine: configure)
            .defaultAppStorage(manager.filingContentDefaults)
        let (host, window) = ReviewLensHost.mount(subject, size: Self.canvas)
        return Mounted(host: host, window: window)
    }

    /// The header card's action row, where the Refine button lives, cropped so a difference in the
    /// list below cannot be mistaken for one here.
    private func toolbarStrip(_ mounted: Mounted) -> NSBitmapImageRep? {
        mounted.host.layoutSubtreeIfNeeded()
        let strip = CGRect(x: 0, y: 0, width: Self.canvas.width, height: 90)
        guard let rep = mounted.host.bitmapImageRepForCachingDisplay(in: strip) else { return nil }
        mounted.host.cacheDisplay(in: strip, to: rep)
        return rep
    }

    private func inkedPixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.alphaComponent > 0.05 && c.brightnessComponent < 0.90 { count += 1 }
            }
        }
        return count
    }

    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return -1 }
        return PixelDiff.differingPixels(a, b, tolerance: 0.02)
    }

    @Test func theRefineControlPaintsWhenThereAreResults() throws {
        let withCloud = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: true))))
        let withoutCloud = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: false))))

        // Both states paint: the cloud-off state carries the "Refine with Claude…" invitation.
        #expect(inkedPixels(withCloud) > 500)
        #expect(inkedPixels(withoutCloud) > 500)
        // And they are not the same control: one label painted in both states fails here.
        #expect(differingPixels(withCloud, withoutCloud) > 200)
    }

    @Test func theInvitationIsWithheldWhenThereIsNowhereToSendTheUser() throws {
        // A host with no Settings to open (the previews, any embedder without the closure) must not
        // paint a button that does nothing. The positive control is the mount that passes one.
        let offered = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: false), configure: {})))
        let withheld = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: false), configure: nil)))

        #expect(inkedPixels(offered) > inkedPixels(withheld))
    }

    @Test func aSavedKeyOffersTheButtonAndNoKeyOffersTheInvitation() throws {
        // A saved key is the whole opt-in. The toolbar asks the cheap seam, never the route, which
        // would read the Keychain on every render, so a saved but unreadable key paints the same
        // button; the pass then says why it could not ask (`FilingRefineHonestTests`).
        //
        // Compared pixel against pixel: both states paint a sparkles button of similar size, so only
        // comparing them catches a branch that picked the wrong one.
        let unreadable = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: true, routesTo: "on-device"),
            configure: {})))
        let working = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: true, routesTo: "cloud:claude-opus-5"),
            configure: {})))
        let invitation = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: false), configure: {})))

        #expect(differingPixels(unreadable, working) == 0,
                "the toolbar resolved the route instead of asking whether a key is saved")
        #expect(differingPixels(working, invitation) > 200,
                "a saved key painted the invitation")
    }

    @Test func changingTheCloudSettingUpdatesTheButtonOnTheNextRender() throws {
        // `filingCloudRefineAvailable` is not `@Published` and nothing observes the key, so the
        // button relies on ContentView re-rendering this lens when the Settings overlay closes.
        // One mounted view across the change, not two fresh mounts, which would pass even if the
        // value were captured at init.
        let m = Self.manager(cloudOn: false)
        let mounted = mount(m, configure: {})
        let before = try #require(toolbarStrip(mounted))

        m.filingCloudRefineConfigured = { true }
        // Re-render the way dismissing the Settings overlay does.
        m.banner = .success("settings closed")
        mounted.host.needsLayout = true
        mounted.host.layoutSubtreeIfNeeded()
        let after = try #require(toolbarStrip(mounted))

        #expect(differingPixels(before, after) > 200,
                "the Refine button did not pick up the cloud setting on re-render")
    }
}
