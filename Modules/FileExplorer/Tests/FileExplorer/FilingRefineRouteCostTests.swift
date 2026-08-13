import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// How often does drawing the Organize toolbar ask the app which backend a refine would use?
///
/// The question matters because of what answering it costs in the real app.
/// `filingBackendIdentity` is wired to `FilingBackendRouter.route(cloudEnabled:hasCloudKey:)`, and
/// `hasCloudKey` is `AnthropicKeychain.hasKey`, which **reads the secret** — a Keychain decrypt
/// that, on a locked or ACL-guarded item, raises the password prompt. `AnthropicKeychain` says so
/// itself and points display-only callers at `isConfigured` instead.
///
/// So this is not a micro-benchmark; it is a correctness net for "the toolbar must not interrogate
/// the Keychain while you type". The deleted `FilingRunPrice` predicted exactly this failure:
/// *"querying the Keychain from a view that re-renders on every keystroke would be far worse than
/// the imprecision."*
@MainActor
@Suite(.serialized) struct FilingRefineRouteCostTests {

    private final class RouteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private static func suggestion(_ name: String) -> FilingSuggestion {
        FilingSuggestion(filePath: "/root/Downloads/\(name)", fileName: name, size: 4_096,
                         modificationDate: Date(timeIntervalSince1970: 0),
                         candidates: [FilingDestination(path: "/root/Documents/Family",
                                                        confidence: .high, reasons: ["t"],
                                                        newSegments: [])],
                         providerRoot: "/root")
    }

    /// Builds the lens in the state the user looks at results in. `configured` mirrors what the
    /// app wires: nil leaves the seam unset, which is the CLI/test shape.
    private func mountToolbar(routes: RouteCounter, displayChecks: RouteCounter?,
                              configured: Bool?) -> NSHostingView<AnyView> {
        // The cloud toggle gates `filingCloudRefineAvailable` before anything else, so without it
        // neither seam is ever consulted and both tests below would pass on an empty toolbar.
        UserDefaults.standard.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        UserDefaults.standard.set("claude-opus-5", forKey: FileSyncManager.cloudModelDefaultsKey)
        let m = FileSyncManager()
        // Stands in for the app's router, whose `.refine` arm reads the Keychain.
        m.filingBackendIdentity = { tier in
            if tier == .refine { routes.hit() }
            return tier == .refine ? "cloud:claude-opus-5" : FileSyncManager.onDeviceBackendIdentity
        }
        if let configured {
            m.filingCloudRefineConfigured = { displayChecks?.hit(); return configured }
        }
        m.publishFilingSuggestions([Self.suggestion("a.pdf"), Self.suggestion("b.pdf")])
        m.hasSuggestedFiling = true
        m.filingScanFolder = "/root/Downloads"
        m.filingLastProviderRoot = "/root"
        m.filingLastTaxonomyFolders = ["Documents", "Documents/Family"]
        m.filingLastExistingFolders = ["Documents", "Documents/Family"]
        m.filingClassifier = { _, _, _ in [:] }

        let size = CGSize(width: 900, height: 620)
        // **Organize opens on its overview, so a filing fixture has to name its lens.** The
        // rail selection lives in defaults, and with the key unset `railLens` is nil — which is
        // the overview, where no lens's own controls are drawn at all. Without this the mount
        // renders a summary page and every assertion about a filing control fails as "painted
        // nothing", which is indistinguishable from the control being broken.
        let defaults = ScratchDefaults("FilingRefineRouteCostTests")
        defaults.set(OrganizeLens.toFile.rawValue, forKey: OrganizeLens.defaultsKey)
        let host = NSHostingView(rootView: AnyView(
            LensWorkspaceView(syncManager: m, lens: .filing, providerName: "Projects",
                     scanTargetFolder: "/root/Downloads", onFindDuplicates: {})
                .defaultAppStorage(defaults)
                .frame(width: size.width, height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for i in 0..<12 {
            m.banner = .success("render \(i)")   // a published change the lens observes
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
        }
        return host
    }

    @Test func drawingTheToolbarDoesNotAskTheRouterPerRender() throws {
        defer {
            UserDefaults.standard.removeObject(forKey: FileSyncManager.usesCloudDefaultsKey)
            UserDefaults.standard.removeObject(forKey: FileSyncManager.cloudModelDefaultsKey)
        }
        // Wired the way the app wires it: a cheap `isConfigured` seam for display, the router
        // reserved for the money decisions.
        let routes = RouteCounter(), display = RouteCounter()
        _ = mountToolbar(routes: routes, displayChecks: display, configured: true)

        let asked = routes.count
        #expect(asked == 0,
                "the Organize toolbar asked the router \(asked) times; in the app each is a Keychain decrypt that can raise the password prompt")
        // The positive control. Without it, "the router was never asked" is equally consistent
        // with a toolbar that stopped drawing the button at all.
        #expect(display.count > 0, "nothing asked whether cloud is configured — the button is gone, not cheap")
    }

    @Test func anUnwiredDisplaySeamStillAnswersCorrectlyByResolvingTheRoute() throws {
        defer {
            UserDefaults.standard.removeObject(forKey: FileSyncManager.usesCloudDefaultsKey)
            UserDefaults.standard.removeObject(forKey: FileSyncManager.cloudModelDefaultsKey)
        }
        // The CLI/test shape. The fallback is the EXPENSIVE path by design — it is the honest
        // answer, and leaving it as the fallback is what keeps `filingCloudRefineAvailable`
        // meaningful for callers with no Keychain. The app must wire the seam; this pins that the
        // unwired behaviour is "correct but costly" rather than "silently no button".
        let routes = RouteCounter()
        _ = mountToolbar(routes: routes, displayChecks: nil, configured: nil)
        #expect(routes.count > 0)
    }
}
