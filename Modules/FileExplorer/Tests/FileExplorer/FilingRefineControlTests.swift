import Testing
import AppKit
import SwiftUI
@testable import Sync
@testable import FileExplorer

/// Does the Refine control actually reach the screen, and does it say the right thing?
///
/// Pixels, because nothing else here is open. The button's label is a `Label` inside a `Button`
/// inside the header card: `fittingSize` cannot see it (the lens fills a fixed frame), and a
/// caption assertion passes vacuously with no assistive client attached to the test process.
///
/// The sharp assertion is `theModelNameOnTheButtonComesFromSettings`: two mounts differing only in
/// the stored model must rasterize differently. A button that hard-coded "Claude", or read a
/// different key than the classifier does, satisfies every "something painted" case here and fails
/// only that one.
///
/// Every setting lives in a scratch suite the manager owns, never the standard domain. A test that
/// shares one store with another renders whichever state won the race, which reads as "the button
/// paints the same thing for Opus and Haiku", the very bug this suite exists to catch.
/// `.serialized` keeps the tests in this process apart but cannot reach another one, and under
/// `swift test` the standard domain is one plist shared by every test process on the machine, which
/// is also the CI runner.
///
/// `.machinePinned(.pixelSampling)` because it reads pixels back out of a live renderer
/// (`colorAt(`): the repo-wide marker for a suite whose verdict is trustworthy only on the
/// recording Mac. The self-hosted run excludes only `liveProfile`, so this still runs there; the
/// marker is what makes it selectable.
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
    /// refine pass needs: the state the lens is in when the user is looking at results.
    ///
    /// Every setting goes to one scratch suite, the manager's `filingContentDefaults`, and `mount`
    /// hands the same suite to the view through `.defaultAppStorage`, so the button and the manager
    /// read one store and can be made to agree, which is what these tests check. A fresh suite per
    /// manager, so no two mounts share one.
    private static func manager(cloudOn: Bool, model: String? = nil,
                                routesTo: String? = nil) -> FileSyncManager {
        let m = FileSyncManager()
        let defaults = ScratchDefaults("FilingRefineControlTests")
        m.filingContentDefaults = defaults
        // `routesTo` stands in for the app's router. nil leaves it unset, so the manager falls back
        // to what the toggle configures, which is what most of these tests want.
        if let routesTo { m.filingBackendIdentity = { _ in routesTo } }
        m.publishFilingSuggestions([suggestion("a.pdf"), suggestion("b.pdf")])
        m.hasSuggestedFiling = true
        m.filingScanFolder = "/root/Downloads"
        m.filingLastProviderRoot = "/root"
        m.filingLastTaxonomyFolders = ["Documents", "Documents/Family"]
        m.filingLastExistingFolders = ["Documents", "Documents/Family"]
        m.filingClassifier = { _, _, _ in [:] }
        // Organize opens on its overview, so a filing fixture has to name its lens. With the rail
        // key unset the selection is nil, the overview, where no lens's own controls are drawn, so
        // every assertion here would fail as "painted nothing", indistinguishable from a broken
        // Refine control.
        //
        // It goes in the same suite as the two cloud settings: `.defaultAppStorage` redirects every
        // `@AppStorage` beneath it, so a store holding only this key would shadow the two this
        // suite exists to vary, and tests would compare two renders of the same button.
        defaults.set(OrganizeLens.toFile.rawValue, forKey: OrganizeLens.defaultsKey)
        defaults.set(cloudOn, forKey: FileSyncManager.usesCloudDefaultsKey)
        if let model { defaults.set(model, forKey: FileSyncManager.cloudModelDefaultsKey) }
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
    /// borderless window's own buffer and every comparison reads as zero difference, "nothing
    /// painted", whatever the code did.
    private func mount(_ manager: FileSyncManager, configure: (() -> Void)? = nil) -> Mounted {
        let subject = LensWorkspaceView(syncManager: manager, lens: .filing,
                               providerName: "Projects", scanTargetFolder: "/root/Downloads",
                               onFindDuplicates: {}, onConfigureCloudRefine: configure)
            .defaultAppStorage(manager.filingContentDefaults)
        let (host, window) = ReviewLensHost.mount(subject, size: Self.canvas)
        return Mounted(host: host, window: window)
    }

    /// The header card's action row, where the Refine button lives, cropped so a difference in the
    /// list below (which these fixtures hold constant anyway) cannot be mistaken for one here.
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
            Self.manager(cloudOn: true, model: "claude-opus-5"))))
        let withoutCloud = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: false))))

        // Both states paint something in the action row: the cloud-off state carries the "Refine
        // with Claude…" invitation, so neither is blank.
        #expect(inkedPixels(withCloud) > 500)
        #expect(inkedPixels(withoutCloud) > 500)
        // And they are not the same control. "Refine 2 with Opus" is wider than the invitation, so
        // a build that painted one label in both states fails here.
        #expect(differingPixels(withCloud, withoutCloud) > 200)
    }

    /// The button no longer names a model: Refine runs on the chat's (TE335), which is a read-out
    /// elsewhere. A pixel diff can't show that, since the label is the same for every model, so the
    /// source is read: the title says Claude, and nothing here reads a model setting of Organize's own.
    @Test func theButtonSaysClaudeAndTheModelIsTheChatsNotOrganizes() throws {
        let source = SourceText.codeOnly(try SourceText.fileExplorer("LensWorkspaceView.swift"))
        #expect(source.contains(#"Label("Refine \(batch.count) with Claude…""#))
        #expect(!source.contains("cloudModelDefaultsKey"), "Organize has no model of its own to read")
        #expect(source.contains("AskClaudeModels.defaultsKey"),
                "the tooltip and Refine Names name the chat's model, read from the setting its menu writes")
    }

    @Test func theInvitationIsWithheldWhenThereIsNowhereToSendTheUser() throws {
        // A host with no Settings to open (the previews, and any embedder that doesn't pass the
        // closure) must not paint a button that does nothing. The positive control is the mount
        // above, which passes one and paints more.
        let offered = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: false), configure: {})))
        let withheld = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: false), configure: nil)))

        #expect(inkedPixels(offered) > inkedPixels(withheld))
    }

    @Test func cloudEnabledWithoutAKeyOffersTheInvitationNotAModelPromise() throws {
        // The downgrade, at the button. Cloud is on, but the router sends this pass to the same
        // on-device model the scan already ran, so the button must not offer "Refine 2 with Opus".
        // The correct control is the invitation, which opens the Settings tab holding the missing
        // key row.
        //
        // Compared against the working cloud state rather than against "something painted": both
        // paint a sparkles button of similar size, so only comparing the two catches a branch that
        // picked the wrong one.
        let downgraded = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: true, model: "claude-opus-5", routesTo: "on-device"),
            configure: {})))
        let working = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: true, model: "claude-opus-5", routesTo: "cloud:claude-opus-5"),
            configure: {})))
        let invitation = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: false), configure: {})))

        #expect(differingPixels(downgraded, working) > 200,
                "cloud-on-without-a-key painted the same button as cloud-on-with-one")
        #expect(differingPixels(downgraded, invitation) == 0,
                "cloud-on-without-a-key should paint exactly the invitation")
    }

    @Test func changingTheCloudSettingUpdatesTheButtonOnTheNextRender() throws {
        // The liveness claim behind the design: `filingCloudRefineAvailable` is not `@Published`
        // and nothing observes the defaults key, so the button depends on SwiftUI re-rendering
        // LensWorkspaceView when the Settings overlay closes, which ContentView does, because
        // dismissing it flips `showSettings` and re-runs the body containing this lens.
        //
        // Asserted on one mounted view across a setting change, not on two fresh mounts: two mounts
        // would pass even if the value were captured at init, which is exactly the failure mode.
        let m = Self.manager(cloudOn: false)
        let mounted = mount(m, configure: {})
        let before = try #require(toolbarStrip(mounted))

        m.filingContentDefaults.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        m.filingContentDefaults.set("claude-opus-5", forKey: FileSyncManager.cloudModelDefaultsKey)
        // Re-render the way dismissing the Settings overlay does.
        m.banner = .success("settings closed")
        mounted.host.needsLayout = true
        mounted.host.layoutSubtreeIfNeeded()
        let after = try #require(toolbarStrip(mounted))

        #expect(differingPixels(before, after) > 200,
                "the Refine button did not pick up the cloud setting on re-render")
    }
}
