import Testing
import AppKit
import SwiftUI
@testable import Sync
@testable import FileExplorer

/// Drawing the Organize toolbar must not ask the app which backend a refine would use.
///
/// In the app `filingBackendIdentity` is `FilingBackendRouter.route(cloudEnabled:hasCloudKey:)`,
/// and `hasCloudKey` is `AnthropicKeychain.hasKey`, which reads the secret: a Keychain decrypt that,
/// on a locked or ACL-guarded item, raises the password prompt. Display-only callers use
/// `isConfigured`. A correctness net, not a benchmark: a view that re-renders on every keystroke
/// would otherwise interrogate the Keychain on every keystroke.
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

    /// Builds the lens in the state the user looks at results in. `configured` mirrors what the app
    /// wires: nil leaves the seam unset, the CLI/test shape.
    private func mountToolbar(routes: RouteCounter, displayChecks: RouteCounter?,
                              configured: Bool?) -> NSHostingView<AnyView> {
        // One scratch suite for the manager and the view alike, never the standard domain, which
        // under `swift test` is one plist shared by every test process on the machine.
        let defaults = ScratchDefaults("FilingRefineRouteCostTests")
        let m = FileSyncManager()
        m.filingContentDefaults = defaults
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
        // Organize opens on its overview (`railLens` nil with the key unset), where no lens's
        // controls are drawn, so a filing fixture must name its lens or nothing here is measured.
        defaults.set(OrganizeLens.toFile.rawValue, forKey: OrganizeLens.defaultsKey)
        let (host, _) = HostedView.framed(
            LensWorkspaceView(syncManager: m, lens: .filing, providerName: "Projects",
                     scanTargetFolder: "/root/Downloads", onFindDuplicates: {})
                .defaultAppStorage(defaults), size: size)
        for i in 0..<12 {
            m.banner = .success("render \(i)")   // a published change the lens observes
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
        }
        return host
    }

    @Test func drawingTheToolbarDoesNotAskTheRouterPerRender() throws {
        // Wired the way the app wires it: a cheap `isConfigured` seam for display, the router
        // reserved for the money decisions.
        let routes = RouteCounter(), display = RouteCounter()
        _ = mountToolbar(routes: routes, displayChecks: display, configured: true)

        let asked = routes.count
        #expect(asked == 0,
                "the Organize toolbar asked the router \(asked) times; in the app each is a Keychain decrypt that can raise the password prompt")
        // The positive control: "never asked" is equally consistent with a toolbar that stopped
        // drawing the button.
        #expect(display.count > 0, "nothing asked whether cloud is configured — the button is gone, not cheap")
    }

    @Test func anUnwiredDisplaySeamStillAnswersCorrectlyByResolvingTheRoute() throws {
        // The CLI/test shape: with the seam unwired the fallback is the expensive, honest path,
        // "correct but costly" rather than "silently no button". The app must wire the seam.
        let routes = RouteCounter()
        _ = mountToolbar(routes: routes, displayChecks: nil, configured: nil)
        #expect(routes.count > 0)
    }
}
