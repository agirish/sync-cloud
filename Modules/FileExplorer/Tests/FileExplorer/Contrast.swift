import AppKit
import Design

/// WCAG contrast, for the readability tests. Both take colours already in sRGB: each caller keeps its
/// own conversion (a bitmap read is raw sRGB bytes; converting it again shifts it).
enum Contrast {
    /// WCAG relative luminance of an sRGB colour.
    static func luminance(_ c: NSColor) -> CGFloat {
        AccentLabel.relativeLuminance(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }

    /// The WCAG contrast ratio of two sRGB colours, 1...21, in either order.
    static func ratio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (x, y) = (luminance(a) + 0.05, luminance(b) + 0.05)
        return max(x, y) / min(x, y)
    }
}
