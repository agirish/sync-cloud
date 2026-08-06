import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// Does the Refine control actually reach the screen, and does it say the right thing?
///
/// **Pixels, because nothing else here is open.** The button's label is a `Label` inside a
/// `Button` inside the header card: `fittingSize` cannot see it (the lens fills a fixed frame),
/// and a caption assertion passes vacuously with no assistive client attached to the test process.
/// A previous feature in this app shipped visibly broken behind forty green tests for exactly this
/// reason — the tests all measured things that could not see paint.
///
/// The sharp assertion is `theModelNameOnTheButtonComesFromSettings`: two mounts differing ONLY in
/// the stored model must rasterize differently. A button that hard-coded "Claude", or read a
/// different key than the classifier does, satisfies every "something painted" case here and fails
/// only that one.
/// **`.serialized`, and it is not a preference.** The view reads the model through `@AppStorage`,
/// which is hard-wired to `UserDefaults.standard`, so every test here writes the same two global
/// keys. Run in parallel — Swift Testing's default — one test's `resetDefaults()` lands between
/// another's write and its mount, and the second renders whichever state won the race. That is a
/// flake that reports as "the button paints the same thing for Opus and Haiku", i.e. as the exact
/// product bug this suite exists to catch.
@MainActor
@Suite(.serialized) struct FilingRefineControlTests {

    private static let canvas = CGSize(width: 900, height: 620)

    private static func suggestion(_ name: String) -> FilingSuggestion {
        FilingSuggestion(
            filePath: "/root/Downloads/\(name)", fileName: name, size: 4_096,
            modificationDate: Date(timeIntervalSince1970: 0),
            candidates: [FilingDestination(path: "/root/Documents/Family", confidence: .high,
                                           reasons: ["test"], newSegments: [])],
            providerRoot: "/root")
    }

    /// A manager holding a COMPLETED Organize scan of `/root/Downloads`, with the cached taxonomy
    /// a refine pass needs — the state the lens is in when the user is looking at results.
    ///
    /// **Both settings go to `UserDefaults.standard`, and that is forced rather than lazy.** The
    /// view reads the model through `@AppStorage`, which is hard-wired to `.standard`, and the
    /// manager's `filingContentDefaults` defaults to `.standard` too — so `.standard` is the one
    /// store where the button and the manager can be made to agree, which is the very thing these
    /// tests are checking. Under `swift test` this is the test runner's own domain, and every
    /// caller removes both keys in a `defer`.
    private static func manager(cloudOn: Bool, model: String? = nil) -> FileSyncManager {
        let m = FileSyncManager()
        m.publishFilingSuggestions([suggestion("a.pdf"), suggestion("b.pdf")])
        m.hasSuggestedFiling = true
        m.filingScanFolder = "/root/Downloads"
        m.filingLastProviderRoot = "/root"
        m.filingLastTaxonomyFolders = ["Documents", "Documents/Family"]
        m.filingLastExistingFolders = ["Documents", "Documents/Family"]
        m.filingClassifier = { _, _, _ in [:] }
        UserDefaults.standard.set(cloudOn, forKey: FileSyncManager.usesCloudDefaultsKey)
        if let model { UserDefaults.standard.set(model, forKey: FileSyncManager.cloudModelDefaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: FileSyncManager.cloudModelDefaultsKey) }
        return m
    }

    /// Removes both keys this suite writes. Every test defers this.
    private static func resetDefaults() {
        UserDefaults.standard.removeObject(forKey: FileSyncManager.cloudModelDefaultsKey)
        UserDefaults.standard.removeObject(forKey: FileSyncManager.usesCloudDefaultsKey)
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
    /// borderless window's own buffer and every comparison reads as zero difference — "nothing
    /// painted", whatever the code did.
    private func mount(_ manager: FileSyncManager, configure: (() -> Void)? = nil) -> Mounted {
        let subject = TidyView(syncManager: manager, lens: .filing,
                               providerName: "Projects", scanTargetFolder: "/root/Downloads",
                               onFindDuplicates: {}, onConfigureCloudRefine: configure)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)

        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return Mounted(host: host, window: window)
    }

    /// The header card's action row, where the Refine button lives — cropped so a difference in
    /// the LIST below (which these fixtures hold constant anyway) cannot be mistaken for one here.
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
        var count = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                if abs(p.redComponent - q.redComponent) > 0.02
                    || abs(p.greenComponent - q.greenComponent) > 0.02
                    || abs(p.blueComponent - q.blueComponent) > 0.02 { count += 1 }
            }
        }
        return count
    }

    @Test func theRefineControlPaintsWhenThereAreResults() throws {
        defer { Self.resetDefaults() }
        let withCloud = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: true, model: "claude-opus-5"))))
        let withoutCloud = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: false))))

        // Both states paint SOMETHING in the action row — the cloud-off state carries the
        // "Refine with Claude…" invitation, so neither is blank.
        #expect(inkedPixels(withCloud) > 500)
        #expect(inkedPixels(withoutCloud) > 500)
        // …and they are not the same control. "Refine 2 with Opus" is wider than the invitation,
        // so a build that painted one label in both states fails here.
        #expect(differingPixels(withCloud, withoutCloud) > 200)
    }

    @Test func theModelNameOnTheButtonComesFromSettings() throws {
        // THE assertion. The button promises a model and the classifier sends to one; if the
        // button read a different key, or hard-coded a name, these two mounts — identical in every
        // other input — would rasterize the same.
        defer { Self.resetDefaults() }
        let opus = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: true, model: "claude-opus-5"))))
        let haiku = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: true, model: "claude-haiku-4-5"))))

        #expect(differingPixels(opus, haiku) > 50,
                "the button paints the same thing for Opus and Haiku — it is not reading the model")
    }

    @Test func theInvitationIsWithheldWhenThereIsNowhereToSendTheUser() throws {
        // A host with no Settings to open (the previews, and any embedder that doesn't pass the
        // closure) must not paint a button that does nothing. The positive control is the mount
        // above, which passes one and paints more.
        defer { Self.resetDefaults() }
        let offered = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: false), configure: {})))
        let withheld = try #require(toolbarStrip(mount(
            Self.manager(cloudOn: false), configure: nil)))

        #expect(inkedPixels(offered) > inkedPixels(withheld))
    }

    @Test func aScanWithNoResultsOffersNoRefine() throws {
        // The setup card's state. Refining nothing is not a thing to offer, and the manager agrees.
        let empty = FileSyncManager()
        #expect(!empty.canRefineFilingSuggestions)
        #expect(empty.filingSuggestionsEligibleForRefine([]).isEmpty)
    }
}
