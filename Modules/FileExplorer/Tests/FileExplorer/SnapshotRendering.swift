import AppKit
import ObjectiveC
import SnapshotTesting
import SwiftUI

// NOTE: This helper is duplicated verbatim in the other snapshot test target: SPM can't share
// test-support code across packages without a production library product, and the harness must
// stay test-only. If you change this file, change the copy too:
//   Modules/Dashboard/Tests/Dashboard/SnapshotRendering.swift

/// Renders a SwiftUI view offscreen at a fixed size, in light and dark, and asserts each against
/// a committed reference under `__Snapshots__/`.
///
/// Renders through a real, never-ordered-in `NSWindow` + `NSHostingView`, not `ImageRenderer`:
/// the hosting view resolves dynamic `NSColor`s, materials and SF Symbols as the app does, and the
/// window pins the appearance instead of following the machine's theme.
///
/// Determinism rules for callers (a flaky snapshot is worse than none):
/// - fixed frame sizes only; never let the content dictate an unstable size
/// - no live dates: freeze `Date` inputs, or pick values whose display bucket is far wider than
///   the render latency, and inject the time zone too: a frozen instant still renders a
///   different string in another zone (see "Image snapshots" in docs/ci.md)
/// - nothing async (QuickLook thumbnails, network images) inside the snapshotted tree
///
/// `precision` and `perceptualPrecision` default to the suite-wide tolerance, under which 1% of
/// the canvas may differ. Tighten them only where a control smaller than that must fail.
@MainActor
func assertViewSnapshot<V: View>(
    of view: V,
    size: CGSize,
    named name: String,
    precision: Float = 0.99,
    perceptualPrecision: Float = 0.98,
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
            // Sub-1.0 precision and perceptual tolerance absorb anti-aliasing jitter without
            // letting a real color or layout change through.
            as: .image(precision: precision, perceptualPrecision: perceptualPrecision),
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
/// Any image not byte-identical to its reference is diffed through `CIAreaAverage` /
/// `CIAreaMaximum`, and the pinned SnapshotTesting passes their `inputExtent` as a bare `CGRect`,
/// which Swift bridges to an `NSValue`. On macOS 27 those filters ask it for `-CGRectValue`, which
/// `CIVector` has and a macOS `NSValue` does not. The uncaught exception aborts the process with
/// no verdict for any test in the package: see "A snapshot mismatch that aborts the process
/// instead of failing" in docs/flaky-tests.md.
///
/// The shim adds the missing selector to `NSValue`, answering with its `rectValue`. Additive
/// only: `class_addMethod` never replaces an implementation, and the guard makes it a no-op where
/// the selector already resolves. Delete this once SnapshotTesting passes a `CIVector`.
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
    // A window-background fill behind every subject: these components are designed against the
    // window chrome, and a transparent PNG makes the light/dark pair meaningless to eyeball.
    // topLeading: when a subject is wider than the canvas (as in the narrow-width truncation
    // scenarios), the visible part starts at the leading edge instead of clipping both sides.
    let subject = view
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)

    let host = NSHostingView(rootView: AnyView(subject))
    host.frame = CGRect(origin: .zero, size: size)

    // Borderless and never ordered in, so nothing flashes on screen, but real enough that
    // appearance, backing store and layout behave as in the app.
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
