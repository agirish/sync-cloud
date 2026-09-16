import AppKit
import ObjectiveC
import SnapshotTesting
import SwiftUI

// NOTE: This helper is intentionally duplicated (verbatim) in the other three test
// targets — SPM offers no clean way to share test-support code across packages without
// minting a production library product, and the harness must stay test-only. If you change
// this file, change the copies too:
//   Modules/Design/Tests/DesignTests/SnapshotRendering.swift
//   Modules/FileExplorer/Tests/FileExplorer/SnapshotRendering.swift
//   Modules/Dashboard/Tests/Dashboard/SnapshotRendering.swift

/// Renders a SwiftUI view to an `NSImage` offscreen at a FIXED size, in the given appearance,
/// and asserts it against a committed reference under `__Snapshots__/`.
///
/// Rendering goes through a real (never-ordered-in) `NSWindow` + `NSHostingView`, not
/// `ImageRenderer`: the hosting view resolves dynamic `NSColor`s, materials and SF Symbols the
/// way the app does, and the window pins the appearance so light/dark are rendered explicitly
/// instead of following the test machine's system theme.
///
/// Determinism ground rules for callers (a flaky snapshot is worse than none):
/// - fixed frame sizes only — never let the content dictate an unstable size
/// - no live dates: freeze `Date` inputs, or pick values whose display bucket is far wider
///   than the test's render latency — and pin the ZONE the date is formatted in by injecting
///   it, rather than leaving the view on `TimeZone.current`. A frozen `Date` is only half of
///   it: the same instant renders a different string once the machine changes zone, which is
///   what sank two Dashboard references on 2026-09-05 (see SNAPSHOTS.md)
/// - nothing async (QuickLook thumbnails, network images) inside the snapshotted tree
@MainActor
func assertViewSnapshot<V: View>(
    of view: V,
    size: CGSize,
    named name: String,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    installPerceptualCompareShim()
    for (variant, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let image = renderOffscreen(view, size: size, appearance: appearance)
        assertSnapshot(
            of: image,
            // Sub-1.0 precision + perceptual tolerance absorb anti-aliasing jitter without
            // letting a real color/layout change through.
            as: .image(precision: 0.99, perceptualPrecision: 0.98),
            named: "\(name)-\(variant)",
            fileID: fileID,
            file: filePath,
            testName: testName,
            line: line,
            column: column
        )
    }
}

/// Makes SnapshotTesting's perceptual compare survive macOS 27, where it otherwise kills the
/// whole test process instead of failing one test.
///
/// Any image that is not byte-identical to its reference — a real change, or the ordinary
/// anti-aliasing jitter `perceptualPrecision` exists to absorb — is diffed through
/// `CIAreaAverage` / `CIAreaMaximum`, and SnapshotTesting (1.19.4, and still `main` as of
/// 2026-09-16) passes those filters' `inputExtent` as a bare `CGRect`. Swift bridges that to an
/// `NSValue`. CoreImage documents the key as a `CIVector`; on macOS 27 its reduction filters ask
/// the value for `-CGRectValue`, which `CIVector` has and a macOS `NSValue` does not (AppKit's
/// spelling is `-rectValue`). The result is an uncaught `NSInvalidArgumentException`, SIGABRT,
/// and no Swift Testing verdict for ANY test in the package — see "A snapshot mismatch that
/// aborts the process instead of failing" in docs/flaky-tests.md.
///
/// The shim gives `NSValue` the missing selector, answering with its `rectValue`. It is
/// additive only: `class_addMethod` never replaces an existing implementation, and the guard
/// makes it a no-op on an OS (or a future SnapshotTesting) where the selector already resolves.
/// `SnapshotPerceptualCompareTests` in Modules/Design proves the compare then reports the right
/// numbers rather than merely not crashing. Delete this once the pinned SnapshotTesting passes a
/// `CIVector`.
func installPerceptualCompareShim() {
    _ = perceptualCompareShim
}

private let perceptualCompareShim: Void = {
    let missing = NSSelectorFromString("CGRectValue")
    guard !NSValue.instancesRespond(to: missing),
          let rectValue = class_getInstanceMethod(NSValue.self, NSSelectorFromString("rectValue"))
    else { return }
    let forward: @convention(block) (NSValue) -> CGRect = { $0.rectValue }
    class_addMethod(
        NSValue.self, missing, imp_implementationWithBlock(forward), method_getTypeEncoding(rectValue))
}()

@MainActor
private func renderOffscreen<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name) -> NSImage {
    // A neutral window-background fill behind every subject: most of these components are
    // designed against the app's window chrome, and a transparent PNG makes the light/dark
    // pair meaningless to eyeball.
    // topLeading: when a subject's minimum size exceeds the canvas (deliberate in the
    // narrow-width truncation scenarios), the visible portion starts at the leading edge
    // instead of clipping both sides symmetrically.
    let subject = view
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)

    let host = NSHostingView(rootView: AnyView(subject))
    host.frame = CGRect(origin: .zero, size: size)

    // Borderless offscreen window: never ordered in (nothing flashes on the test machine's
    // screen), but real enough that appearance, backing store and layout behave like the app.
    let window = NSWindow(
        contentRect: host.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.colorSpace = .sRGB
    window.contentView = host
    host.layoutSubtreeIfNeeded()

    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        fatalError("Could not create bitmap rep for \(size)")
    }
    host.cacheDisplay(in: host.bounds, to: rep)
    let image = NSImage(size: host.bounds.size)
    image.addRepresentation(rep)
    return image
}
