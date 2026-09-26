import AppKit
import Design
import Settings
import Sync
import SwiftUI
import Testing
@testable import SyncCloud

/// Photographs all ten setup screens, so a person can look at them.
///
/// **Off unless `SETUP_GALLERY` names a directory**, so it costs a normal run and CI nothing. It is
/// a tool rather than an assertion, and it is kept because the defects it found could not have been
/// found any other way: a segmented control centred 32pt right of everything else, three cards of
/// three heights, two tiles with the same label, a tree sliced through the middle of a word. Every
/// one of those is invisible to a layout assertion and obvious in a picture, and rebuilding this
/// from nothing is most of a day.
///
/// Two things it must keep doing, both learned the expensive way:
///
/// - **Render through a real `NSWindow`.** Half the ink on the Welcome screen arrives in an
///   `onAppear` animation; an offscreen `cacheDisplay` never fires one, so a harness without a
///   window photographs blank artwork and reports it as a defect. It did.
/// - **Take `startScreen`, and give each screen its own sheet.** `@StateObject`'s `wrappedValue`
///   builds a *new* object on every access outside a view, so setting `model.screen` on a sheet
///   held as a value sets it on an instance the renderer never sees — the first version of this
///   photographed ten copies of whichever screen the defaults implied.
///
/// ```sh
/// TEST_RUNNER_SETUP_GALLERY=/tmp/shots xcodebuild test … -only-testing:SyncCloudTests/SetupScreenGallery
/// ```
@MainActor
@Suite struct SetupScreenGallery {

    private func manager() async -> SettingsManager {
        // **One of each kind, plus a second Drive account.** The Locations screen and its Why panel
        // both turn on how many *kinds* of location there are — the panel draws one mark per kind —
        // so a fixture of three Google Drive accounts photographs a one-mark strip and says nothing
        // about the four-mark row a real Mac draws.
        let folders = [
            "Dropbox",
            "OneDrive-Personal",
            "GoogleDrive-personal@example.com",
            "GoogleDrive-work@example.com",
        ].map { URL(fileURLWithPath: "/private/tmp/render/CloudStorage/\($0)") }
        let defaults = ScratchDefaults("render")
        let m = SettingsManager(autoDiscover: false, userDefaults: defaults,
                                cloudStorageLister: { CloudStorageAccounts(folders: folders, rootWasReadable: true) },
                                pathValidator: { _ in true })
        await m.discoverProviders()
        return m
    }

    private func roster() throws -> PeopleStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-roster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PeopleStore(directory: dir, profileId: "render", profile: nil)
        for name in ["Mother", "Daughter", "Son"] {
            store.add(displayName: name, relationship: name == "Mother" ? "family" : "family")
        }
        return store
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SETUP_GALLERY"] != nil))
    func photographEveryScreen() async throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SETUP_GALLERY"]!)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let settings = await manager()
        let people = try roster()
        let host = CGSize(width: 1200, height: 740)

        for scheme in [ColorScheme.light, .dark] {
            for scale in FontSize.allCases.map(\.scale) {
                if scheme == .dark && scale != 1.0 { continue }
                for screen in SetupFlow.Screen.allCases {
                    let sheet = SetupSheet(
                        settings: settings, peopleStore: people, glassHue: .blue,
                        glassLevel: .frosted, surfaceTint: 0, availableSize: host,
                        hasFilingProfile: false,
                        defaults: ScratchDefaults("render-d"),
                        walk: SetupSheetFitTests.realisticWalk, startScreen: screen,
                        onOpenSettings: { _ in }, onFinish: {}, onDismiss: {})
                    let w = host.width, h = host.height
                    // The whole sheet, not just the card: `onAppear` on the sheet is what runs
                    // `model.onOpen()`, which seeds the name from the Mac account. A card rendered
                    // on its own photographs every name field empty.
                    let view = sheet
                        .frame(width: w, height: h)
                        .environment(\.appFontScale, scale)
                        .environment(\.colorScheme, scheme)
                        .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
                    // **In a real window, because `onAppear` is where half the ink is.** Several
                    // illustrations start at `opacity(0)` and are brought in by an `onAppear`
                    // animation; an offscreen `cacheDisplay` never fires it, so a harness without a
                    // window photographs blank artwork and reports it as a defect.
                    let hv = NSHostingView(rootView: view)
                    hv.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    hv.frame = CGRect(x: 0, y: 0, width: w, height: h)
                    let window = NSWindow(contentRect: hv.frame,
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = hv
                    window.appearance = hv.appearance
                    window.orderFront(nil)
                    hv.layoutSubtreeIfNeeded()
                    for _ in 0..<8 {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
                    }
                    guard let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) else { continue }
                    hv.cacheDisplay(in: hv.bounds, to: rep)
                    window.orderOut(nil)
                    let tag = "\(scheme == .dark ? "dark" : "light")-\(Int(scale * 100))"
                    let name = "\(String(format: "%02d", (screen.number ?? 0)))-\(screen)-\(tag).png"
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try data.write(to: out.appendingPathComponent(name))
                    }
                }
            }
        }
        print("[gallery] wrote to \(out.path)")
        // How much of the card each screen's own content actually uses.
        let ceiling = SetupSheetMetrics.contentHeight(availableSize: host, scale: 1)
        let sheet = SetupSheet(
            settings: settings, peopleStore: people, glassHue: .blue, glassLevel: .frosted,
            surfaceTint: 0, availableSize: host, hasFilingProfile: false,
            defaults: ScratchDefaults("render-m"),
            walk: SetupSheetFitTests.realisticWalk, startScreen: .welcome,
            onOpenSettings: { _ in }, onFinish: {}, onDismiss: {})
        print("[gallery] ceiling \(Int(ceiling))")
        // **Measured at every text size, not just the default.** The card's width scales with the
        // text and its height stops at the window, so the budget a screen is held to changes shape
        // as the size rises — a measurement taken only at 100% cannot see the size that overflows.
        // The scale has to reach the layout too: `screenBody` read at the ambient 100% reports the
        // height of type nobody is looking at.
        for size in FontSize.allCases {
            let scale = size.scale
            let ceiling = SetupSheetMetrics.contentHeight(availableSize: host, scale: scale)
            for screen in SetupFlow.Screen.allCases {
                let w = SetupSheetMetrics.contentWidth(availableSize: host, scale: scale,
                                                       screen: screen)
                let hv = NSHostingView(rootView: sheet.screenBody(screen)
                    .environment(\.appFontScale, scale)
                    .environment(\.setupCardScale, SetupSheetMetrics.cardScale(
                        availableSize: host, scale: scale))
                    .frame(width: w))
                hv.layoutSubtreeIfNeeded()
                let used = hv.fittingSize.height
                let over = used > ceiling ? "  OVER by \(Int(used - ceiling))" : ""
                print("[gallery] \(size.percent)% \(screen) \(Int(used))pt of \(Int(ceiling))"
                      + " — \(Int(used / ceiling * 100))%\(over)")
            }
        }
    }
}
